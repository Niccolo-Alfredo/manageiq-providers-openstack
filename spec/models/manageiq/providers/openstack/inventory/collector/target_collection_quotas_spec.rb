# frozen_string_literal: true

require "spec_helper"

describe ManageIQ::Providers::Openstack::Inventory::Collector::TargetCollection do
  let(:tenant_id) { "tenant-uuid-123" }
  let(:tenant_name) { "test-tenant" }
  let(:cloud_tenant_refs) { [] }
  let(:manager) { FactoryBot.create(:ems_openstack, :zone => EvmSpecHelper.local_miq_server.zone) }
  let(:target) do
    t = double(
      "InventoryRefresh::TargetCollection",
      :targets                            => [],
      :manager_refs_by_association_reset => nil
    )
    allow(t).to receive(:manager_refs_by_association).and_return(manager_refs_by_association_stub)
    allow(t).to receive(:add_target).with(any_args)
    t
  end
  let(:manager_refs_by_association_stub) do
    {
      :vms                   => { :ems_ref => [] },
      :orchestration_stacks   => { :ems_ref => [] },
      :cloud_volumes          => { :ems_ref => [] },
      :cloud_tenants          => { :ems_ref => cloud_tenant_refs }
    }
  end
  let(:collector) { described_class.new(manager, target) }

  let(:os_handle) { double("OpenstackHandle") }
  let(:tenant_object) { double("Tenant", :id => tenant_id, :name => tenant_name) }
  let(:identity_svc) { double("IdentityService", :visible_tenants => [tenant_object]) }

  before do
    allow(manager).to receive(:openstack_handle).and_return(os_handle)
    allow(os_handle).to receive(:identity_service).and_return(identity_svc)
  end

  describe "#quotas" do
    context "when target includes a cloud tenant and Compute returns quotas" do
      let(:cloud_tenant_refs) { [tenant_id] }
      let(:compute_svc) { double("Fog::OpenStack::Compute") }
      let(:quota_body) do
        { "quota_set" => { "cores" => 10, "instances" => 5, "ram" => 20_480 } }
      end

      before do
        allow(os_handle).to receive(:tenants).and_return([tenant_object])
        allow(os_handle).to receive(:detect_service).with("Compute", tenant_name).and_return(compute_svc)
        allow(os_handle).to receive(:detect_service).with("Volume", tenant_name).and_return(nil)
        allow(os_handle).to receive(:detect_service).with("Network", tenant_name).and_return(nil)
        allow(compute_svc).to receive(:get_quota).with(tenant_id).and_return(double(:body => quota_body))
      end

      it "returns an array" do
        expect(collector.quotas).to be_an(Array)
      end

      it "returns at least one quota hash for the tenant" do
        result = collector.quotas
        expect(result).not_to be_empty
        compute_quota = result.find { |q| q["tenant_id"] == tenant_id && q["service_name"] == "Compute" }
        expect(compute_quota).to be_present
        expect(compute_quota["cores"]).to eq(10)
        expect(compute_quota["instances"]).to eq(5)
        expect(compute_quota["ram"]).to eq(20_480)
      end
    end

    context "when get_quota raises (soft error)" do
      let(:cloud_tenant_refs) { [tenant_id] }
      let(:compute_svc) { double("Fog::OpenStack::Compute") }

      before do
        allow(os_handle).to receive(:tenants).and_return([tenant_object])
        allow(os_handle).to receive(:detect_service).with("Compute", tenant_name).and_return(compute_svc)
        allow(os_handle).to receive(:detect_service).with("Volume", tenant_name).and_return(nil)
        allow(os_handle).to receive(:detect_service).with("Network", tenant_name).and_return(nil)
        allow(compute_svc).to receive(:get_quota).and_raise(Excon::Errors::NotFound.new("Not found"))
      end

      it "does not raise" do
        expect { collector.quotas }.not_to raise_error
      end

      it "returns an array" do
        expect(collector.quotas).to be_an(Array)
      end

      it "returns an empty array when all services fail" do
        expect(collector.quotas).to eq([])
      end
    end

    context "when tenant id is not in tenants list" do
      let(:cloud_tenant_refs) { [tenant_id] }

      before do
        allow(os_handle).to receive(:tenants).and_return([])
      end

      it "does not raise" do
        expect { collector.quotas }.not_to raise_error
      end

      it "returns an empty array" do
        expect(collector.quotas).to eq([])
      end
    end

    context "when references(:cloud_tenants) is empty" do
      let(:cloud_tenant_refs) { [] }

      it "returns an empty array without calling the handle" do
        expect(os_handle).not_to receive(:tenants)
        expect(collector.quotas).to eq([])
      end
    end
  end
end
