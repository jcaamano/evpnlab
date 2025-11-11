#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# THESE CAN BE REDIFINED EXTERNALLY

# Set this to 0 if using a cluster where EVPN is not implemented yet or the EVPN
# feature gate is disabled
EVPN_IMPLEMENTED=${EVPN_IMPLEMENTED:-1}

FRR_K8S_VERSION=${FRR_K8S_VERSION:-v0.0.14}
FRR_VERSION=${FRR_VERSION:-10.4.1}

# external networks will be allocated within these subnets
AGNHOST_SUBNET_V4=${AGNHOST_SUBNET_V4:-172.20.0.0/16}
AGNHOST_SUBNET_V6=${AGNHOST_SUBNET_V6:-2001:db8:2::/48}

# for each of these names, define a <EXTRA_NETWORK>_NETWORK_SUBNET_V[4|6]
# of have a devscripts config in ./dev-scripts-additional-config
EXTRA_NETWORK_NAMES=${EXTRA_NETWORK_NAMES:-}

# FRR default IP and GW, using /24 and /64 prefixes
FRR_IP=${FRR_IP:-192.168.111.3}
FRR_GW=${FRR_GW:-192.168.111.1}
FRR_IP6=${FRR_IP6:-fd2e:6f44:5dd8:c956::3}
FRR_GW6=${FRR_GW6:-fd2e:6f44:5dd8:c956::1}

# default cluster network
CLUSTER_NETWORK_V4=${CLUSTER_NETWORK_V4:-10.128.0.0/14}
CLUSTER_NETWORK_V6=${CLUSTER_NETWORK_V6:-fd01::/48}


# source devscripts configuration
[ -e ~/dev-scripts-additional-config ] && source ~/dev-scripts-additional-config

FRR_TMP_DIR=$(mktemp -d -u)

setup_commands() {
  local sudo
  if [ "$EUID" -ne 0 ]; then
    sudo="sudo"
  fi

  CCLI="$sudo podman"
  if ! command -v "podman"; then
      CCLI="$sudo docker"
  fi
  echo "Container CLI is: $CCLI"
 
  KCLI="oc"
  if ! command -v $KCLI; then
    KCLI="kubectl"
  fi
  echo "kube CLI is: $KCLI"

  IP="$sudo ip"
  IPTABLES="$sudo iptables"
  IP6TABLES="$sudo ip6tables"
  BRIDGE="$sudo bridge"
}

setup_cluster() {
  # enable route advertisement with FRR
  $KCLI patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled","gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'

  echo "Waiting for namespace 'openshift-frr-k8s' to be created..."
  until $KCLI get namespace "openshift-frr-k8s" &> /dev/null; do
    sleep 5
  done
  echo "Namespace 'openshift-frr-k8s' has been created."

  echo "Waiting for daemonset 'frr-k8s' to be created..."
  until $KCLI rollout status daemonset -n openshift-frr-k8s frr-k8s --timeout 2m &> /dev/null; do
    sleep 5
  done

  #WEBHOOK_DEPLOYMENT=frr-k8s-webhook-server
  WEBHOOK_DEPLOYMENT=frr-k8s-statuscleaner
  echo "Waiting for deploy '$WEBHOOK_DEPLOYMENT' to be created..."
  until $KCLI wait -n openshift-frr-k8s deployment $WEBHOOK_DEPLOYMENT --for condition=Available --timeout 2m &> /dev/null; do
    sleep 5
  done

  # override FRR-K8s with an upstream image needed to support EVPN
  $KCLI patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"managementState": "Unmanaged"}}'
  $KCLI set image -n openshift-frr-k8s ds/frr-k8s frr=quay.io/frrouting/frr:10.4.1 reloader=quay.io/frrouting/frr:$FRR_VERSION
  echo "Waiting for daemonset 'frr-k8s' to rollout..."
  until $KCLI rollout status daemonset -n openshift-frr-k8s frr-k8s --timeout 2m &> /dev/null; do
    sleep 5
  done
}

setup_cluster_evpn() {
  [ "$EVPN_IMPLEMENTED" = "0" ] || return 0

  $KCLI get pods -l app=ovnkube-node -A -o custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name,NODEIP:.status.podIP --no-headers |\
  while read NAMESPACE POD NODEIP; do
    local configure_evpn="
      ip link del br0 || true;
      ip link del vxlan0 || true;
      ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0;
      ip link set br0 addrgenmode none;
      ip link add vxlan0 type vxlan dstport 4789 local $NODEIP nolearning external vnifilter;
      ip link set vxlan0 addrgenmode none master br0;
      ip link set br0 up;
      ip link set vxlan0 up;
      bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off;
      "
    $KCLI exec -n $NAMESPACE $POD -c ovnkube-controller -- /bin/sh -c "$configure_evpn"
  done
}

configure_cluster_macvrf() {
  [ "$EVPN_IMPLEMENTED" = "0" ] || return 0

  local network=$1
  local vid=$2
  local vni=$3
  local switch=cluster_udn_${network}_ovn_layer2_switch
  local port=cluster_udn_${network}_evpn_port

  $KCLI get pods -l app=ovnkube-node -A -o custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name --no-headers |\
  while read NAMESPACE POD; do
    local configure_macvrf="
      # clean up
      ovn-nbctl --if-exists lsp-del ${port};
      ovs-vsctl --if-exists del-port br-int evpn${vni};
      ip link del vlan$vid || true;
      
      # setup vid <-> vni mapping
      bridge vlan add dev br0 vid $vid self;
      bridge vlan add dev vxlan0 vid $vid;
      bridge vni add dev vxlan0 vni $vni;
      bridge vlan add dev vxlan0 vid $vid tunnel_info id $vni;
      
      # setup SVI
      ip link add vlan$vid link br0 type vlan id $vid;
      ip link set vlan$vid master $network
      ip link set vlan$vid up

      # setup OVN access port
      ovs-vsctl add-port br-int evpn${vni} -- set interface evpn${vni} type=internal external-ids:iface-id=${port};
      ip link set evpn${vni} master br0;
      bridge vlan add dev evpn${vni} vid $vid pvid untagged;
      ip link set evpn${vni} up
      ovn-nbctl lsp-add $switch ${port};
      ovn-nbctl lsp-set-addresses $port unknown
      # delete all transit remote ports since E/W traffic now goes through the EVPN
      ovn-nbctl get Logical_Switch ${switch} ports | tr -d '[],' | tr ' ' '\n' | xargs -I{} ovn-nbctl -f csv --columns _uuid,type list Logical_Switch_Port {} | grep remote | cut -d',' -f1 |\
        xargs -I{} ovn-nbctl lsp-del {}
      "
    $KCLI exec -n $NAMESPACE $POD -c ovnkube-controller -- /bin/sh -c "$configure_macvrf"
  done
}

configure_cluster_ipvrf() {
  [ "$EVPN_IMPLEMENTED" = "0" ] || return 0

  local network=$1
  local vid=$2
  local vni=$3
  local router=cluster_udn_${network}_ovn_cluster_router
  
  $KCLI get pods -l app=ovnkube-node -A -o custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name --no-headers |\
  while read NAMESPACE POD; do
    local configure_ipvrf="
      # clean up
      ip link del vlan$vid || true;
      
      # setup vid <-> vni mapping
      bridge vlan add dev br0 vid $vid self;
      bridge vlan add dev vxlan0 vid $vid;
      bridge vni add dev vxlan0 vni $vni;
      bridge vlan add dev vxlan0 vid $vid tunnel_info id $vni;
      
      # setup SVI
      ip link add vlan$vid link br0 type vlan id $vid;
      ip link set vlan$vid master $network
      ip link set vlan$vid up

      # delete routes to the transit network since traffic now goes through the EVPN
      ovn-nbctl get Logical_Router ${router} static_routes | tr -d '[],' | tr ' ' '\n' | xargs -I{} ovn-nbctl -f csv --columns _uuid,nexthop list Logical_Router_Static_Route {} | grep -E '(100.88|fd97::)' | cut -d',' -f1 |\
        xargs -I{} ovn-nbctl remove logical_router ${router} static_routes {}
      "
    $KCLI exec -n $NAMESPACE $POD -c ovnkube-controller -- /bin/sh -c "$configure_ipvrf"
  done
}

AGNHOST_SUBNET_SEQ=100
declare OUT_AGNHOST_SUBNET_IP
declare OUT_AGNHOST_SUBNET_IP6
declare OUT_AGNHOST_SUBNET_GW
declare OUT_AGNHOST_SUBNET_GW6
allocate_agnhost_subnet() {
  local seq=$AGNHOST_SUBNET_SEQ
  OUT_AGNHOST_SUBNET_IP=${AGNHOST_SUBNET_V4/.0.0\/16/.${seq}.2/24}
  OUT_AGNHOST_SUBNET_IP6=${AGNHOST_SUBNET_V6/::\/48/::${seq}:2/64}
  OUT_AGNHOST_SUBNET_GW=${AGNHOST_SUBNET_V4/.0.0\/16/.${seq}.1/24}
  OUT_AGNHOST_SUBNET_GW6=${AGNHOST_SUBNET_V6/::\/48/::${seq}:1/64}
  ((AGNHOST_SUBNET_SEQ+=1))
}

deploy_agnhost_network() {
  local name=${1:-}
  local ip=${2:-}
  local ip6=${3:-}
  local gw=${4:-}
  local gw6=${5:-}
  local link=${6:-}
  local link6=${7:-}

  local container=agnhost_$name
  local network=${container}_net
  local agnhost_veth=${name}1
  local frr_veth=${name}2

  # cleanup
  $CCLI rm -f $container || true

  # run agnhost
  $CCLI run -d --privileged --name $container --hostname $container --network none --rm registry.k8s.io/e2e-test-images/agnhost:2.40 netexec --http-port=8000

  # find out what is the highest frr eth index
  local index
  index=$($CCLI exec frr ip -j l | jq -r '.[] | .ifname' | grep eth | sed 's|eth||' | sort -r | head -1)
  ((index+=1))

  # create direct connection between agnhost and frr container with a veth pair
  agnhost_ns=$($CCLI inspect --format '{{.NetworkSettings.SandboxKey}}' $container)
  frr_ns=$($CCLI inspect --format '{{.NetworkSettings.SandboxKey}}' frr)
  $IP link add agnhosttemp type veth peer name frrtemp
  $IP link set agnhosttemp netns $agnhost_ns
  $IP link set frrtemp netns $frr_ns
  $CCLI exec $container ip link set agnhosttemp name eth0
  $CCLI exec frr ip link set frrtemp name eth$index
  $CCLI exec $container ip link set eth0 up
  $CCLI exec frr ip link set eth$index up

  # set agnhost network config
  [ -n "$ip" ] && $CCLI exec $container ip address replace dev eth0 $ip
  [ -n "$ip6" ] && $CCLI exec $container ip -6 address replace dev eth0 $ip6
  [ -n "$link" ] && $CCLI exec $container ip route replace $link dev eth0
  [ -n "$link6" ] && $CCLI exec $container ip route replace $link6 dev eth0
  [ -n "$gw" ] && $CCLI exec $container ip route replace default dev eth0 via ${gw/\/*/}
  [ -n "$gw6" ] && $CCLI exec $container ip -6 route replace default dev eth0 via ${gw6/\/*/}
  echo ""
}

configure_network() {
  local name=$1

  # allocate IPs for the network
  allocate_agnhost_subnet

  # create network
  deploy_agnhost_network $name $OUT_AGNHOST_SUBNET_IP $OUT_AGNHOST_SUBNET_IP6 $OUT_AGNHOST_SUBNET_GW $OUT_AGNHOST_SUBNET_GW6

  # create & connect agnhost container
  # find out what is the highest eth index
  local index
  index=$($CCLI exec frr ip -j l | jq -r '.[] | .ifname' | grep eth | sed 's|eth||' | sort -r | head -1)
  $CCLI exec frr ip address replace dev eth$index $OUT_AGNHOST_SUBNET_GW
  $CCLI exec frr ip -6 address replace dev eth$index $OUT_AGNHOST_SUBNET_GW6
}

configure_network_vrflite() {
  local vrf=$1

  # cleanup
  $IP link delete frr${vrf} || true

  # find out what is the highest eth index
  local index
  index=$($CCLI exec frr ip -j l | jq -r '.[] | .ifname' | grep eth | sed 's|eth||' | sort -r | head -1)
  ((index+=1))
  
  # create VRF
  $CCLI exec frr ip link add $vrf type vrf table $index
  $CCLI exec frr ip link set dev $vrf up
  $CCLI exec frr ip route replace table $index unreachable default metric 4278198272
  $CCLI exec frr ip -6 route replace table $index unreachable default dev lo metric 4278198272
 
  # create direct connection between ${vrf} bridge and frr container with a veth pair
  frr_ns=$($CCLI inspect --format '{{.NetworkSettings.SandboxKey}}' frr)
  $IP link add frr${vrf} type veth peer name frrtemp
  $IP link set frr${vrf} master ${vrf}
  $IP link set frrtemp netns $frr_ns
  $CCLI exec frr ip link set frrtemp name eth$index
  $IP link set frr${vrf} up
  $CCLI exec frr ip link set eth$index up

  # attach the frr container to the extra network and add to VRF
  local subnet_v4_var=${vrf^^}_NETWORK_SUBNET_V4
  local subnet_v6_var=${vrf^^}_NETWORK_SUBNET_V6
  local ip=${!subnet_v4_var/\.0\//.3\/}
  local ip6=${!subnet_v6_var/::\//::3\/}
  #$CCLI network connect ${vrf}_net frr
  $CCLI exec frr ip link set dev eth$index master $vrf
  $CCLI exec frr ip address replace dev eth$index $ip
  $CCLI exec frr ip -6 address replace dev eth$index $ip6

  # create agnhost network on default vrf
  configure_network $vrf
  # then attach to vrf
  ((index+=1))
  $CCLI exec frr ip link set dev eth$index master $vrf
}

configure_network_macvrf() {
  local network=${1}
  local vid=$2
  local vni=$3
  local cidr=$4

  # configure the VLAN/VID mapping on the EVPN bridge/VTEP
  $CCLI exec frr bridge vlan add dev br0 vid $vid self
  $CCLI exec frr bridge vlan add dev vxlan0 vid $vid
  $CCLI exec frr bridge vni add dev vxlan0 vni $vni
  $CCLI exec frr bridge vlan add dev vxlan0 vid $vid tunnel_info id $vni

  # let's assign our external client a sufficiently high non-subnet IP
  # FIXME: this assumes the cidr has a network IP where only the non-prefix part is zeroed out
  local ip=${cidr//.0/.250}
  ip=${ip///*//16} 
  # create agnhost network
  deploy_agnhost_network ${network}_macvrf $ip "" "" "" $cidr

  # find out what is the last eth index
  local index
  index=$($CCLI exec frr ip -j l | jq -r '.[] | .ifname' | grep eth | sed 's|eth||' | sort -r | head -1)
  # add to bridge as an access port to the macvrf
  $CCLI exec frr ip link set eth$index master br0
  $CCLI exec frr bridge vlan add dev eth$index vid $vid pvid untagged
}

configure_network_ipvrf() {
  local network=${1}
  local vid=$2
  local vni=$3

  # find out what is the highest eth index
  local index
  index=$($CCLI exec frr ip -j l | jq -r '.[] | .ifname' | grep eth | sed 's|eth||' | sort -r | head -1)
  ((index+=1))

  # create VRF
  $CCLI exec frr ip link add $network type vrf table $index
  $CCLI exec frr ip link set dev $network up

  # configure the VLAN/VID mapping on the EVPN bridge/VTEP
  $CCLI exec frr bridge vlan add dev br0 vid $vid self
  $CCLI exec frr bridge vlan add dev vxlan0 vid $vid
  $CCLI exec frr bridge vni add dev vxlan0 vni $vni
  $CCLI exec frr bridge vlan add dev vxlan0 vid $vid tunnel_info id $vni

  # configure the SVI
  $CCLI exec frr ip link add vlan$vid link br0 type vlan id $vid
  $CCLI exec frr ip link set vlan$vid addrgenmode none
  $CCLI exec frr ip link set vlan$vid master $network
  $CCLI exec frr ip link set vlan$vid up

  # create agnhost network on default vrf
  configure_network ${network}_ipvrf
  # then attach to vrf
  local index
  index=$($CCLI exec frr ip -j l | jq -r '.[] | .ifname' | grep eth | sed 's|eth||' | sort -r | head -1)
  $CCLI exec frr ip link set eth$index master $network
}

deploy_networks() {
  local -n vrfs=$1
  local -n macvrfs=$2
  local -n ipvrfs=$3
  local -n l2vids=$4
  local -n l3vids=$5
  local -n l2vnis=$6
  local -n l3vnis=$7

  # configure a network over the default VRF and attach agnhost contianer
  configure_network default

  for vrf in "${!vrfs[@]}"; do
    [ "default" = "$vrf" ] && continue
    
    # configure a network over the vrf and attach agnhost contianer
    configure_network_vrflite $vrf
  done

  for macvrf in "${!macvrfs[@]}"; do
    local vid=${l2vids["$macvrf"]}
    local vni=${l2vnis["$macvrf"]}
    configure_network_macvrf $macvrf $vid $vni ${macvrfs["$macvrf"]}
    configure_cluster_macvrf $macvrf $vid $vni
  done

  for ipvrf in "${!ipvrfs[@]}"; do
    local vid=${l3vids["$ipvrf"]}
    local vni=${l3vnis["$ipvrf"]}
    configure_network_ipvrf $ipvrf $vid $vni
    configure_cluster_ipvrf $ipvrf $vid $vni
  done
}

clone_frr() {
  [ -d "$FRR_TMP_DIR" ] || {
    mkdir -p "$FRR_TMP_DIR" && trap 'rm -rf $FRR_TMP_DIR' EXIT
    pushd "$FRR_TMP_DIR" || exit 1
    git clone --depth 1 --branch $FRR_K8S_VERSION https://github.com/metallb/frr-k8s
    popd || exit 1
  }
}

generate_frr_config() {
    local output_file="$1"  # Get output file path argument
    local neighbors_ref=$2
    local macvrfs_ref=$3
    local ipvrfs_ref=$4
    local l3vnis_ref=$5

    local -n neighbors=$neighbors_ref
    local -n macvrfs=$macvrfs_ref
    local -n ipvrfs=$ipvrfs_ref
    local -n l3vnis=$l3vnis_ref

    echo "log file /etc/frr/frr.log debugging" > "$output_file"
    
    for vrf in "${!neighbors[@]}"; do
      local ipv4_list=()
      local ipv6_list=()
      # First filter out IPv4 addresses
      for ip in ${neighbors[$vrf]}; do
          if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              ipv4_list+=("$ip")
          else
              ipv6_list+=("$ip")
          fi
      done
      
      [ "default" = "$vrf" ] && {
        echo "router bgp 64512" >> "$output_file"
      } || {
        echo "router bgp 64512 vrf $vrf" >> "$output_file"
      }

      echo " no bgp default ipv4-unicast" >> "$output_file"

      # Generate neighbor remote-as section
      for ip in "${ipv4_list[@]}"; do
          echo " neighbor $ip remote-as 64512" >> "$output_file"
      done
      echo "" >> "$output_file"

      for ip in "${ipv6_list[@]}"; do
          echo " neighbor $ip remote-as 64512" >> "$output_file"
      done
      echo "" >> "$output_file"

      echo " address-family ipv4 unicast" >> "$output_file"
      #echo "  network ${AGNHOST_SUBNET_V4}" >> "$output_file"
      echo "  redistribute connected" >> "$output_file"
      for ip in "${ipv4_list[@]}"; do
          echo "  neighbor $ip activate" >> "$output_file"
          echo "  neighbor $ip next-hop-self" >> "$output_file"
          echo "  neighbor $ip route-reflector-client" >> "$output_file"
      done
      echo " exit-address-family" >> "$output_file"
      echo "" >> "$output_file"

      echo " address-family ipv6 unicast" >> "$output_file"
      #echo "  network ${AGNHOST_SUBNET_V6}" >> "$output_file"
      echo "  redistribute connected" >> "$output_file"
      for ip in "${ipv6_list[@]}"; do
          echo "  neighbor $ip activate" >> "$output_file"
          echo "  neighbor $ip next-hop-self" >> "$output_file"
          echo "  neighbor $ip route-reflector-client" >> "$output_file"
      done
      echo " exit-address-family" >> "$output_file"
      echo "" >> "$output_file"

      if [[ -z "${ipvrfs[*]-}" ]] && [[ -z "${macvrfs[*]-}" ]]; then
        continue
      fi

      if [ "default" = "$vrf" ]; then
        echo " address-family l2vpn evpn" >> "$output_file"
        echo "  advertise-all-vni" >> "$output_file"
        for ip in "${ipv4_list[@]}"; do
          echo "  neighbor $ip activate" >> "$output_file"
          echo "  neighbor $ip route-reflector-client" >> "$output_file"
        done
        echo " exit-address-family" >> "$output_file"
        echo "" >> "$output_file"
      fi
      echo "exit" >> "$output_file"
      echo "" >> "$output_file"
    done

    for ipvrf in "${!ipvrfs[@]}"; do
      local vni=${l3vnis["$ipvrf"]}
      echo "vrf $ipvrf" >> "$output_file"
      echo " vni $vni" >> "$output_file"
      echo "exit-vrf" >> "$output_file"
      echo "router bgp 64512 vrf $ipvrf" >> "$output_file"
      echo " address-family ipv4 unicast" >> "$output_file"
      echo "  redistribute connected" >> "$output_file"
      echo " exit-address-family" >> "$output_file"
      echo " address-family l2vpn evpn" >> "$output_file"
      echo "  advertise ipv4 unicast" >> "$output_file"
      echo " exit-address-family" >> "$output_file"
      echo "" >> "$output_file"
      echo "exit" >> "$output_file"
      echo "" >> "$output_file"
    done
}

deploy_frr() {
  echo "Deploying FRR external container ..."
  clone_frr
  
  local frr_config=$(mktemp -d -t frr-XXXXXXXXXX)
  local bgp_networks_ref=$1
  local macvrfs_ref=$2
  local ipvrfs_ref=$3
  local l3vnis_ref=$4

  generate_frr_config ${frr_config}/frr.conf $bgp_networks_ref $macvrfs_ref $ipvrfs_ref $l3vnis_ref
  
  cp "${FRR_TMP_DIR}"/frr-k8s/hack/demo/frr/daemons $frr_config
  chmod a+rw ${frr_config}/*

  # cleanup
  $CCLI rm -f frr || true
  $CCLI network rm -f ostestbm_net || true
  
  # create a container network connected to the cluster network by attaching to the existing ostestbm bridge
  $CCLI network create --driver bridge --ipam-driver=none --opt com.docker.network.bridge.name=ostestbm ostestbm_net
  # run frr
  $CCLI run -d --rm --privileged --ulimit core=-1 --network ostestbm_net --name frr --volume "$frr_config":/etc/frr quay.io/frrouting/frr:$FRR_VERSION

  # main interface is on the cluster bridge, use default network gateway
  $CCLI exec frr ip address replace dev eth0 ${FRR_IP}/24
  $CCLI exec frr ip route replace default dev eth0 via ${FRR_GW}
  $CCLI exec frr ip -6 address replace dev eth0 ${FRR_IP6}/64
  $CCLI exec frr ip -6 route replace default dev eth0 via ${FRR_GW6}

  # create the general EVPN configuration: bridge with SVD
  $CCLI exec frr ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
  $CCLI exec frr ip link set br0 addrgenmode none
  $CCLI exec frr ip link add vxlan0 type vxlan dstport 4789 local ${FRR_IP} nolearning external vnifilter
  $CCLI exec frr ip link set vxlan0 addrgenmode none master br0
  $CCLI exec frr ip link set br0 up
  $CCLI exec frr ip link set vxlan0 up
  # configure vxlan to map vni <-> vid
  $CCLI exec frr bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off
  
  # ipv4 forwarding is enabled by default, we only need to turn on ipv6 forwarding
  $CCLI exec frr sysctl -w net.ipv6.conf.all.forwarding=1
}

configure_ocp() {

  local nets_ref=$1
  local macvrfs_ref=$2
  local ipvrfs_ref=$3
  local l3vnis_ref=$4

  local -n nets=$nets_ref
  local -n macvrfs=$macvrfs_ref
  local -n ipvrfs=$ipvrfs_ref
  local -n l3vnis=$l3vnis_ref

  # Setup cluster BGP peering and route advertisements
  for network in "${nets[@]}"; do
    label="network: ${network}"
    vrf=
    targetVRF=
    raw=
    neighbor=
    neighbor6=
    neighbors=
    if [ "default" = "$network" ]; then
      name=receive-filtered
      neighbor=${FRR_IP}
      neighbor6=${FRR_IP6}
      network_selector=$(cat <<EOF
    - networkSelectionType: DefaultNetwork  
EOF
)
      # raw config to enable EVPN on default VRF
      if [ "$EVPN_IMPLEMENTED" = "0" ]; then
        if [[ -n "${ipvrfs[*]-}" ]] || [[ -n "${macvrfs[*]-}" ]]; then
          raw=$(cat <<EOF
  raw:
    rawConfig: |+
      router bgp 64512
        address-family l2vpn evpn
          advertise-all-vni
          neighbor $neighbor activate
        exit-address-family
      exit
EOF
)
        fi
      fi
    else
      [ "$EVPN_IMPLEMENTED" = "0" ] || continue

      # if [[ -v bgp_networks["$network"] ]]; then
      #  subnet_v4_var=${network^^}_NETWORK_SUBNET_V4
      #  subnet_v6_var=${network^^}_NETWORK_SUBNET_V6
      # hack: we would not define neighbors for EVPN CUDNs but for now we need 
      # the to trick the RA or it will reject the config
      if true; then
        subnet_v4_var=${EXTRA_NETWORK^^}_NETWORK_SUBNET_V4
        subnet_v6_var=${EXTRA_NETWORK^^}_NETWORK_SUBNET_V6
        # end hack
        neighbor=${!subnet_v4_var/\.0\/*/.3}
        neighbor6=${!subnet_v6_var/::\/*/::3}
      fi
      if [[ -v ipvrf_networks["$network"] ]]; then
        # raw config to advertise the IPVRF
        prefix=${ipvrfs["$network"]}
        vni=${l3vnis["$network"]}
        raw=$(cat <<EOF
  raw:
    rawConfig: |+
      router bgp 64512 vrf ${network}
        address-family l2vpn evpn
          advertise ipv4 unicast
        exit-address-family
      exit
      vrf ${network}
        vni $vni
      exit-vrf
EOF
)
      fi
  
      name=receive-filtered-$network
      vrf="vrf: ${network}"
      targetVRF=${network}
      network_selector=$(cat <<EOF
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            ${label}
EOF
)
    fi
    if [ -n "$neighbor$neighbor6" ]; then
      neighbors="neighbors:"
    fi
    if [ -n "$neighbor" ]; then
      neighbors+=$'\n'
      neighbors+=$(cat <<EOF
      - address: $neighbor
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - prefix: ${AGNHOST_SUBNET_V4}   
              le: 32
EOF
)     
    fi
    if [ -n "$neighbor6" ]; then
      neighbors+=$'\n'
      neighbors+=$(cat <<EOF
      - address: $neighbor6
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - prefix: ${AGNHOST_SUBNET_V6}   
              le: 128
EOF
)     
    fi
  
    frrconfig=$(cat <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: ${name}
  namespace: openshift-frr-k8s
  labels:
    ${label}
spec:
${raw}
  bgp:
    routers:
    - asn: 64512
      ${vrf}
      ${neighbors}
EOF
)
    oc apply -f - <<EOF
$frrconfig
EOF

    # advertise the network
    ra=$(cat <<EOF
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: ${network}
spec:
  targetVRF: ${targetVRF}
  nodeSelector: {}
  networkSelectors:
${network_selector}
  frrConfigurationSelector:
    matchLabels:
      ${label}
  advertisements:
    - "PodNetwork"
EOF
)
    oc apply -f - <<EOF
$ra
EOF

  done

}

# This script configures BGP to advertise and connect pod networks in different
# ways.

# initial setup
setup_commands

# configure the cluster
setup_cluster
setup_cluster_evpn

# track the networks that we will be setting up
declare -a networks

# track networks over which BGP sessions are stablished
declare -A bgp_networks

# for the default network BGP sessions are stablished over node IPs
bgp_networks["default"]=$($KCLI get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
networks+=("default")

# BGP sessions will also be established over extra networks defined in devscripts
# EXTRA_NETWORK_NAMES in VRF-Lite configuration 
# TODO: support more that one network
EXTRA_NETWORK=$(echo ${EXTRA_NETWORK_NAMES:-} | awk '{print $1;}')
if [ -n "$EXTRA_NETWORK" ]; then   
  # track this network to stablish a BGP session on it as well
  bgp_networks["$EXTRA_NETWORK"]=$(sudo virsh net-dumpxml $EXTRA_NETWORK | xmllint --xpath '/network//host/@ip' - | cut -d '=' -f2 | tr -d \" | xargs)
  networks+=("$EXTRA_NETWORK")
fi

declare -A l2vids
declare -A l3vids
declare -A l2vnis
declare -A l3vnis
vid=100

# get CUDNs for L2 EVPN
declare -A macvrf_networks
for network in $($KCLI get clusteruserdefinednetwork -l macvrf=true -o jsonpath='{..metadata.name}'); do
  cidr=$($KCLI get clusteruserdefinednetwork.k8s.ovn.org $network -o json | jq -r '.spec.network.layer2.subnets[0] // empty')
  vni=$($KCLI get clusteruserdefinednetwork.k8s.ovn.org $network -o json | jq -r '.spec.network.evpn.macVRF.vni // empty')
  [ -n "$vni" ] || vni=$((vid+10000000))
  macvrf_networks["$network"]=$cidr
  networks+=("$network")
  l2vnis["$network"]=$vni
  l2vids["$network"]=$vid
  ((vid+=1))
done

# get CUDNs for L3 EVPN
declare -A ipvrf_networks
for network in $($KCLI get clusteruserdefinednetwork -l ipvrf=true -o jsonpath='{..metadata.name}'); do
  cidr=$($KCLI get clusteruserdefinednetwork.k8s.ovn.org $network -o json | jq -r '.spec.network.layer3.subnets[0].cidr // empty')
  [ -z "$cidr" ] && cidr=$($KCLI get clusteruserdefinednetwork.k8s.ovn.org $network -o json | jq -r '.spec.network.layer2.subnets[0] // empty')
  vni=$($KCLI get clusteruserdefinednetwork.k8s.ovn.org $network -o json | jq -r '.spec.network.evpn.ipVRF.vni // empty')
  [ -n "$vni" ] || vni=$((vid+10000000))
  ipvrf_networks["$network"]=$cidr
  networks+=("$network")
  l3vnis["$network"]=$vni
  l3vids["$network"]=$vid
  ((vid+=1))
done

# deploy external BGP router
deploy_frr bgp_networks macvrf_networks ipvrf_networks l3vnis

# deploy actual networks with an external container attached
deploy_networks bgp_networks macvrf_networks ipvrf_networks l2vids l3vids l2vnis l3vnis

# seems like there is a race between FRR-K8s applying the configuration and FRR
# noticing the host configuration changes that validate the configuration, the
# configurtation fials to apply silently and FRR-K8s does not retry
# sleep and give cluster frr time to notice the changes
sleep 10

# configure FRR-k8s and RAs
configure_ocp networks macvrf_networks ipvrf_networks l3vnis

# make sure the default pod network can flow through the host/libvirt bridge
CLUSTER_NETWORK_V4="10.128.0.0/14"
$IP route replace $CLUSTER_NETWORK_V4 via ${FRR_IP} dev ostestbm
$IPTABLES -t filter -I FORWARD -s ${CLUSTER_NETWORK_V4} -i ostestbm -j ACCEPT
$IPTABLES -t filter -I FORWARD -d ${CLUSTER_NETWORK_V4} -o ostestbm -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
$IPTABLES -t nat -I POSTROUTING -s ${CLUSTER_NETWORK_V4} ! -d ${FRR_GW} -j MASQUERADE

CLUSTER_NETWORK_V6="fd01::/48"
$IP -6 route replace $CLUSTER_NETWORK_V6 via ${FRR_IP6} dev ostestbm
$IP6TABLES -t filter -I FORWARD -s ${CLUSTER_NETWORK_V6} -i ostestbm -j ACCEPT
$IP6TABLES -t filter -I FORWARD -d ${CLUSTER_NETWORK_V6} -o ostestbm -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
$IP6TABLES -t nat -I POSTROUTING -s ${CLUSTER_NETWORK_V6} ! -d ${FRR_GW6} -j MASQUERADE
