#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if ! [ -d state ]; then
  exit "No State, exiting"
  exit 1
fi

if ! [ -d opsfiles ]; then
  mkdir opsfiles
fi

source ./state/env.sh
: ${NETWORK_NAME:?"!"}
: ${CONCOURSE_IP:?"!"}
: ${CONCOURSE_DEPLOYMENT_NAME:?"!"}
: ${OPENSTACK_HOST:?"!"}
: ${OPENSTACK_USERNAME:?"!"}
: ${OPENSTACK_PASSWORD:?"!"}
: ${OPENSTACK_PROJECT:?"!"}
: ${OPENSTACK_DOMAIN:?"!"}

export OS_PROJECT_NAME=$OPENSTACK_PROJECT
export OS_USERNAME=$OPENSTACK_USERNAME
export OS_PASSWORD=$OPENSTACK_PASSWORD
export OS_AUTH_URL=http://$OPENSTACK_HOST/v2.0
set -x

NETWORK_UUID=$(openstack network show $NETWORK_NAME -c id -f value)

mkdir -p bin
PATH=$PATH:$(pwd)/bin

if ! [ -f bin/bosh ]; then
  curl -L "http://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.1-linux-amd64" > bin/bosh
  chmod +x bin/bosh
fi

if ! [ -f state/concourse-manifest.yml ]; then
  curl -L 'https://raw.githubusercontent.com/concourse/concourse/c8a9ab4d5fb3be4f0343f3552b1da241a59dae92/manifests/single-vm.yml' > state/concourse-manifest.yml
fi

cat > opsfiles/concourse-init-opsfile.yml <<EOF
- type: replace
  path: /cloud_provider?
  value: 
    mbus: https://mbus:p2an3m7idfm6vmqp3w74@((web_ip)):6868
    template:
      name: openstack_cpi
      release: bosh-openstack-cpi
    ssh_tunnel: 
      host: ((web_ip)) # <--- Replace with your Elastic IP address
      port: 22
      user: vcap
      private_key: ./bosh.pem # Path relative to this manifest file
    properties:
      agent:
        mbus: https://mbus:p2an3m7idfm6vmqp3w74@0.0.0.0:6868
      blobstore:
        path: /var/vcap/micro_bosh/data/cache
        provider: local
      openstack:
        auth_url: ((auth_url))
        username: ((openstack_username))
        api_key: ((openstack_password))
        domain: ((openstack_domain))
        tenant: ((openstack_tenant))
        project: ((openstack_project))
        region: ((region))
        default_key_name: ((default_key_name))
        default_security_groups: ((default_security_groups))
        human_readable_vm_names: true
      ntp:
      - time1.google.com
      - time2.google.com
      - time3.google.com
      - time4.google.com
- type: replace
  path: /releases
  value:
  - name: concourse
    sha1: 99e134676df72e18c719ccfbd7977bd9449e6fd4
    url: https://bosh.io/d/github.com/concourse/concourse?v=3.8.0
  - name: garden-runc
    url: https://bosh.io/d/github.com/cloudfoundry/garden-runc-release?v=1.9.0
    sha1: 77bfe8bdb2c3daec5b40f5116a6216badabd196c
  - name: postgres
    url: https://bosh.io/d/github.com/cloudfoundry/postgres-release?v=23
    sha1: 4b5265bfd5f92cf14335a75658658a0db0bca927
  - name: bosh-openstack-cpi
    url: https://bosh.io/d/github.com/cloudfoundry-incubator/bosh-openstack-cpi-release?v=35
    sha1: 314b040cb0df72651174d262892aa8c4d75f9031
- type: replace
  path: /resource_pools?
  value: 
    - name: vms
      network: default
      stemcell:
        sha1: 4f3501a3c374e7e107ee1219ff08d55aa5001331
        url: https://bosh.io/d/stemcells/bosh-openstack-kvm-ubuntu-trusty-go_agent?v=3468.19
      cloud_properties:
        instance_type: concourse
      env:
        bosh:
          password: '*'
- type: replace
  path: /networks?
  value:
  - name: default
    subnets:
    - dns:
      - 10.0.0.2
      gateway: 10.0.0.1
      range: 10.0.0.0/24
      static_ips: ((web_ip))
      cloud_properties:
        net_id: ((net_id))
        security_groups: ((default_security_groups))
    type: manual
- type: replace
  path: /instance_groups/name=concourse/resource_pool?
  value: vms 
- type: replace
  path: /instance_groups/name=concourse/networks?
  value: 
    - default:
      - dns
      - gateway
      name: default
      static_ips:
      - ((web_ip))
- type: replace
  path: /instance_groups/name=concourse/jobs/name=tsa/properties/bind_port?
  value: 2222
- type: replace
  path: /instance_groups/name=concourse/jobs/name=groundcrew/properties/baggageclaim?
  value:
    url: http://127.0.0.1:7788
- type: replace
  path: /instance_groups/name=concourse/jobs/name=groundcrew/properties/tsa/host?
  value: 127.0.0.1
- type: replace
  path: /instance_groups/name=concourse/jobs/name=groundcrew/properties/tsa/host_public_key?
  value: ((tsa_host_key.public_key))
- type: replace
  path: /instance_groups/name=concourse/jobs/name=groundcrew/properties/tsa/port?
  value: 2222
- type: replace
  path: /instance_groups/name=concourse/jobs/name=atc/properties/postgresql/host?
  value: 127.0.0.1 
EOF

if ! [ -f state/bosh.pem ]; then
  ssh-keygen -f state/bosh.pem -N ''
  chmod 600 state/bosh.pem
fi

if ! [ -f state/token_signing_key ]; then
  ssh-keygen -f state/token_signing_key -N '' -m PEM
  ssh-keygen -e -y -m PEM -f state/token_signing_key > state/token_signing_key.pub.pem
fi

if ! [ -f state/tsa_host_key ]; then
  ssh-keygen -f state/tsa_host_key -N ''
  ssh-keygen -y -f state/tsa_host_key > state/tsa_host_key.pub
  ssh-keygen -l -E md5 -f state/tsa_host_key.pub | sed 's/.*MD5:\([a-f0-9:]*\).*/\1/' > state/tsa_host_key.fingerprint
fi

if ! [ -f state/worker_key ]; then
  ssh-keygen -f state/worker_key -N ''
  ssh-keygen -y -f state/worker_key > state/worker_key.pub
  ssh-keygen -l -E md5 -f state/worker_key.pub | sed 's/.*MD5:\([a-f0-9:]*\).*/\1/' > state/worker_key.fingerprint
fi

if ! grep -q concourse <(openstack flavor list -c Name -f value); then
  openstack flavor create \
    concourse \
    --public \
    --vcpus 2 \
    --ram 8192 \
    --disk 50 \
  ;
fi

if ! grep -q concourse <(openstack security group list -c Name -f value); then
  openstack security group create concourse
  openstack security group rule create concourse --protocol=tcp --dst-port=8080   # web
  openstack security group rule create concourse --protocol=tcp --dst-port=6868   # bosh create-env
  openstack security group rule create concourse --protocol=tcp --dst-port=22     # debugging
  openstack security group rule create concourse --protocol=icmp                  # debugging
fi

if ! grep -q concourse <(openstack keypair list -c Name -f value); then
  openstack keypair create --public-key=state/bosh.pem.pub concourse
fi

if ! dpkg -l build-essential ruby; then
  DEBIAN_FRONTEND=noninteractive sudo apt-get -qqy update
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -qqy \
    build-essential zlibc zlib1g-dev ruby ruby-dev openssl libxslt-dev libxml2-dev libssl-dev libreadline6 libreadline6-dev libyaml-dev libsqlite3-dev sqlite3
fi

bosh create-env state/concourse-manifest.yml \
  --state state/concourse-state.json \
  -o opsfiles/concourse-init-opsfile.yml \
  -v admin_password=admin \
  -v api_key=password \
  -v auth_url=http://$OPENSTACK_HOST/v2.0 \
  -v az=nova \
  -v default_key_name=concourse \
  -v default_security_groups=[concourse] \
  -v director_name=concourse \
  -v web_ip=$CONCOURSE_IP \
  -v net_id=$NETWORK_UUID \
  -v network_name=$NETWORK_NAME \
  -v openstack_password=$OPENSTACK_PASSWORD \
  -v openstack_project=$OPENSTACK_PROJECT \
  -v openstack_tenant=$OPENSTACK_PROJECT \
  -v openstack_username=$OPENSTACK_USERNAME \
  -v openstack_domain=$OPENSTACK_DOMAIN \
  -v private_key=bosh.pem \
  -v region=RegionOne \
  -v vm_type=m1.medium \
  -v concourse_version=3.8.0 \
  -v deployment_name=$CONCOURSE_DEPLOYMENT_NAME \
  -v garden_runc_version=1.9.0 \
  -v postgres_password=password \
  -v token_signing_key=$(
       jq -n \
         --arg private_key "$(cat state/token_signing_key)" \
         --arg public_key "$(cat state/token_signing_key.pub.pem)" \
         '{private_key: $private_key, public_key: $public_key}' \
       ;
     ) \
  -v tsa_host_key=$(
       jq -n \
         --arg private_key "$(cat state/tsa_host_key)" \
         --arg public_key "$(cat state/tsa_host_key.pub)" \
         --arg fingerprint "$(cat state/tsa_host_key.fingerprint)" \
         '{private_key: $private_key, public_key: $public_key, public_key_fingerprint: $fingerprint}' \
       ;
     ) \
  -v worker_key=$(
       jq -n \
         --arg private_key "$(cat state/worker_key)" \
         --arg public_key "$(cat state/worker_key.pub)" \
         --arg fingerprint "$(cat state/worker_key.fingerprint)" \
         '{private_key: $private_key, public_key: $public_key, public_key_fingerprint: $fingerprint}' \
       ;
     ) \
;
