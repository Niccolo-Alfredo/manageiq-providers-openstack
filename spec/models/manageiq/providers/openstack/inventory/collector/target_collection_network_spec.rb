# frozen_string_literal: true

require "spec_helper"

describe ManageIQ::Providers::Openstack::Inventory::Collector::TargetCollection do
  let(:tenant_id) { "tenant-uuid-123" }
  let(:tenant_name) { "test-tenant" }
  let(:cloud_tenant_refs) { [] }
  let(:vm_refs) { [] }
  let(:network_port_refs) { [] }
  let(:security_group_refs) { [] }
  let(:firewall_rule_refs) { [] }
  let(:cloud_subnet_refs) { [] }
  let(:cloud_network_refs) { [] }
  let(:network_router_refs) { [] }
  let(:manager) { FactoryBot.create(:ems_openstack, :zone => EvmSpecHelper.local_miq_server.zone) }
  let(:target) do
    t = double(
      "InventoryRefresh::TargetCollection",
      :targets                           => [],
      :manager_refs_by_association_reset => nil
    )
    allow(t).to receive(:manager_refs_by_association).and_return(manager_refs_by_association_stub)
    allow(t).to receive(:add_target).with(any_args)
    t
  end
  let(:manager_refs_by_association_stub) do
    {
      :vms                  => {:ems_ref => vm_refs},
      :orchestration_stacks => {:ems_ref => []},
      :cloud_volumes        => {:ems_ref => []},
      :cloud_tenants        => {:ems_ref => cloud_tenant_refs},
      :network_ports        => {:ems_ref => network_port_refs},
      :security_groups      => {:ems_ref => security_group_refs},
      :firewall_rules       => {:ems_ref => firewall_rule_refs},
      :cloud_subnets        => {:ems_ref => cloud_subnet_refs},
      :cloud_networks       => {:ems_ref => cloud_network_refs},
      :network_routers      => {:ems_ref => network_router_refs},
    }
  end
  let(:collector) { described_class.new(manager, target) }

  let(:os_handle) { double("OpenstackHandle") }
  let(:network_svc) { double("Fog::OpenStack::Network") }
  let(:compute_svc) { double("Fog::OpenStack::Compute") }
  let(:identity_svc) { double("IdentityService", :visible_tenants => []) }

  before do
    allow(manager).to receive(:openstack_handle).and_return(os_handle)
    allow(os_handle).to receive(:detect_network_service).and_return(network_svc)
    allow(os_handle).to receive(:detect_compute_service).and_return(compute_svc)
    allow(os_handle).to receive(:identity_service).and_return(identity_svc)
  end

  describe "#network_ports" do
    context "when no refs present" do
      it "returns empty array" do
        expect(collector.network_ports).to eq([])
      end
    end

    context "when network_port refs present" do
      let(:network_port_refs) { ["port-1", "port-2"] }
      let(:port1) { double("Port", :id => "port-1") }
      let(:port2) { double("Port", :id => "port-2") }
      let(:ports_collection) { double("PortsCollection") }

      before do
        allow(network_svc).to receive(:ports).and_return(ports_collection)
        allow(ports_collection).to receive(:get).with("port-1").and_return(port1)
        allow(ports_collection).to receive(:get).with("port-2").and_return(port2)
      end

      it "fetches ports by id" do
        result = collector.network_ports
        expect(result).to contain_exactly(port1, port2)
      end
    end

    context "when cloud_tenant refs present" do
      let(:cloud_tenant_refs) { [tenant_id] }
      let(:tenant_port1) { double("Port", :id => "tp-1") }
      let(:tenant_port2) { double("Port", :id => "tp-2") }

      before do
        allow(network_svc).to receive(:handled_list)
          .with(:ports, {:tenant_id => tenant_id}, true)
          .and_return([tenant_port1, tenant_port2])
      end

      it "fetches all ports for tenant" do
        result = collector.network_ports
        expect(result).to contain_exactly(tenant_port1, tenant_port2)
      end
    end

    context "when both port refs and tenant refs present" do
      let(:network_port_refs) { ["port-1"] }
      let(:cloud_tenant_refs) { [tenant_id] }
      let(:port1) { double("Port", :id => "port-1") }
      let(:tenant_port) { double("Port", :id => "tp-1") }
      let(:ports_collection) { double("PortsCollection") }

      before do
        allow(network_svc).to receive(:ports).and_return(ports_collection)
        allow(ports_collection).to receive(:get).with("port-1").and_return(port1)
        allow(network_svc).to receive(:handled_list)
          .with(:ports, {:tenant_id => tenant_id}, true)
          .and_return([tenant_port])
      end

      it "merges and deduplicates results" do
        result = collector.network_ports
        expect(result).to contain_exactly(port1, tenant_port)
      end
    end

    context "when tenant fetch returns duplicate of port ref" do
      let(:network_port_refs) { ["port-1"] }
      let(:cloud_tenant_refs) { [tenant_id] }
      let(:port1) { double("Port", :id => "port-1") }
      let(:ports_collection) { double("PortsCollection") }

      before do
        allow(network_svc).to receive(:ports).and_return(ports_collection)
        allow(ports_collection).to receive(:get).with("port-1").and_return(port1)
        allow(network_svc).to receive(:handled_list)
          .with(:ports, {:tenant_id => tenant_id}, true)
          .and_return([port1])
      end

      it "deduplicates by id" do
        result = collector.network_ports
        expect(result.size).to eq(1)
      end
    end
  end

  describe "#security_groups" do
    context "when no refs present" do
      it "returns empty array" do
        expect(collector.security_groups).to eq([])
      end
    end

    context "when security_group refs present" do
      let(:security_group_refs) { ["sg-1"] }
      let(:sg1) { double("SecurityGroup", :id => "sg-1") }

      before do
        allow(os_handle).to receive(:detect_network_service).and_return(network_svc)
        allow(collector).to receive(:openstack_network_admin?).and_return(false)
        allow(network_svc).to receive(:handled_list)
          .with(:security_groups, {}, false)
          .and_return([sg1])
      end

      it "fetches all security groups" do
        result = collector.security_groups
        expect(result).to contain_exactly(sg1)
      end
    end

    context "when cloud_tenant refs present" do
      let(:cloud_tenant_refs) { [tenant_id] }
      let(:sg1) { double("SecurityGroup", :id => "sg-t1") }

      before do
        allow(network_svc).to receive(:handled_list)
          .with(:security_groups, {:tenant_id => tenant_id}, true)
          .and_return([sg1])
      end

      it "fetches security groups for tenant" do
        result = collector.security_groups
        expect(result).to contain_exactly(sg1)
      end
    end

    context "when both SG refs and tenant refs present" do
      let(:security_group_refs) { ["sg-1"] }
      let(:cloud_tenant_refs) { [tenant_id] }
      let(:sg1) { double("SecurityGroup", :id => "sg-1") }
      let(:sg2) { double("SecurityGroup", :id => "sg-t1") }

      before do
        allow(collector).to receive(:openstack_network_admin?).and_return(true)
        allow(network_svc).to receive(:handled_list)
          .with(:security_groups, {}, true)
          .and_return([sg1])
        allow(network_svc).to receive(:handled_list)
          .with(:security_groups, {:tenant_id => tenant_id}, true)
          .and_return([sg2])
      end

      it "merges and deduplicates" do
        result = collector.security_groups
        expect(result).to contain_exactly(sg1, sg2)
      end
    end
  end

  describe "#firewall_rules" do
    context "when no refs present" do
      it "returns empty array" do
        expect(collector.firewall_rules).to eq([])
      end
    end

    context "when firewall_rule refs present" do
      let(:firewall_rule_refs) { ["fwr-1"] }
      let(:rule1) { double("FirewallRule", :id => "fwr-1") }

      before do
        allow(network_svc).to receive(:handled_list)
          .with(:security_group_rules, {}, true)
          .and_return([rule1])
      end

      it "fetches all firewall rules" do
        result = collector.firewall_rules
        expect(result).to contain_exactly(rule1)
      end
    end

    context "when security_group refs present" do
      let(:security_group_refs) { ["sg-1"] }
      let(:rule1) { double("FirewallRule", :id => "fwr-1") }

      before do
        allow(network_svc).to receive(:handled_list)
          .with(:security_group_rules, {}, true)
          .and_return([rule1])
      end

      it "fetches firewall rules when SG refs exist" do
        result = collector.firewall_rules
        expect(result).to contain_exactly(rule1)
      end
    end

    context "when cloud_tenant refs present" do
      let(:cloud_tenant_refs) { [tenant_id] }
      let(:rule1) { double("FirewallRule", :id => "fwr-t1") }

      before do
        allow(network_svc).to receive(:handled_list)
          .with(:security_group_rules, {}, true)
          .and_return([rule1])
      end

      it "fetches firewall rules when tenant refs exist" do
        result = collector.firewall_rules
        expect(result).to contain_exactly(rule1)
      end
    end
  end

  describe "#cloud_subnets" do
    context "when no refs present" do
      it "returns empty array" do
        expect(collector.cloud_subnets).to eq([])
      end
    end

    context "when cloud_subnet refs present" do
      let(:cloud_subnet_refs) { ["subnet-1"] }
      let(:subnet1) { double("Subnet", :id => "subnet-1") }

      before do
        allow(network_svc).to receive(:handled_list)
          .with(:subnets, {}, true)
          .and_return([subnet1])
      end

      it "fetches all subnets" do
        result = collector.cloud_subnets
        expect(result).to contain_exactly(subnet1)
      end
    end

    context "when cloud_network refs present" do
      let(:cloud_network_refs) { ["net-1"] }
      let(:subnet1) { double("Subnet", :id => "subnet-1") }

      before do
        allow(network_svc).to receive(:handled_list)
          .with(:subnets, {}, true)
          .and_return([subnet1])
      end

      it "fetches subnets when network refs exist" do
        result = collector.cloud_subnets
        expect(result).to contain_exactly(subnet1)
      end
    end

    context "when network_port refs present" do
      let(:network_port_refs) { ["port-1"] }
      let(:subnet1) { double("Subnet", :id => "subnet-1") }

      before do
        allow(network_svc).to receive(:handled_list)
          .with(:subnets, {}, true)
          .and_return([subnet1])
      end

      it "fetches subnets when port refs exist" do
        result = collector.cloud_subnets
        expect(result).to contain_exactly(subnet1)
      end
    end

    it "memoizes results" do
      allow(cloud_subnet_refs).to receive(:blank?).and_return(false)
      # Force refs to be non-blank for this test
      stub = manager_refs_by_association_stub.merge(
        :cloud_subnets => {:ems_ref => ["subnet-1"]}
      )
      allow(target).to receive(:manager_refs_by_association).and_return(stub)
      collector2 = described_class.new(manager, target)

      subnet1 = double("Subnet", :id => "subnet-1")
      allow(network_svc).to receive(:handled_list)
        .with(:subnets, {}, true)
        .and_return([subnet1])

      result1 = collector2.cloud_subnets
      result2 = collector2.cloud_subnets
      expect(result1).to equal(result2)
      expect(network_svc).to have_received(:handled_list).with(:subnets, {}, true).once
    end
  end

  describe "#server_groups" do
    context "when no VM refs present" do
      it "returns empty array" do
        expect(collector.server_groups).to eq([])
      end
    end

    context "when VM refs present" do
      let(:vm_refs) { ["vm-1"] }
      let(:sg) { double("ServerGroup", :id => "sg-1", :members => []) }

      before do
        allow(compute_svc).to receive(:handled_list)
          .with(:server_groups, {}, true)
          .and_return([sg])
        # stub server fetch for infer_related_vm_ems_refs_api!
        allow(compute_svc).to receive(:servers).and_return(double(:get => nil))
      end

      it "fetches server groups" do
        result = collector.server_groups
        expect(result).to contain_exactly(sg)
      end

      it "memoizes results" do
        collector.server_groups
        collector.server_groups
        expect(compute_svc).to have_received(:handled_list).with(:server_groups, {}, true).once
      end
    end
  end
end
