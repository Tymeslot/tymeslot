Code.require_file(
  "dev_support/credo_checks/no_saas_reference_in_core.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoSaasReferenceInCoreTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoSaasReferenceInCore

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags an alias of a TymeslotSaas module" do
      """
      defmodule Tymeslot.Billing do
        alias TymeslotSaas.Billing
      end
      """
      |> to_source_file("lib/tymeslot/billing.ex")
      |> run_check(NoSaasReferenceInCore)
      |> assert_issue(fn issue -> assert issue.trigger == "TymeslotSaas" end)
    end

    test "flags a qualified call into TymeslotSaas" do
      """
      defmodule Tymeslot.Billing do
        def active?(user), do: TymeslotSaas.Billing.active?(user)
      end
      """
      |> to_source_file("lib/tymeslot/billing.ex")
      |> run_check(NoSaasReferenceInCore)
      |> assert_issue()
    end

    test "flags Application.get_env/2 reading the :tymeslot_saas application" do
      """
      defmodule Tymeslot.Billing do
        def plan, do: Application.get_env(:tymeslot_saas, :plan)
      end
      """
      |> to_source_file("lib/tymeslot/billing.ex")
      |> run_check(NoSaasReferenceInCore)
      |> assert_issue(fn issue -> assert issue.trigger == "Application.get_env" end)
    end
  end

  describe "accepted cases" do
    test "accepts an alias of an ordinary Core module" do
      """
      defmodule Tymeslot.Billing do
        alias Tymeslot.Meetings
      end
      """
      |> to_source_file("lib/tymeslot/billing.ex")
      |> run_check(NoSaasReferenceInCore)
      |> refute_issues()
    end

    test "accepts Application.get_env/3 reading Core's own config key" do
      """
      defmodule Tymeslot.Billing do
        def enforce_legal_agreements?,
          do: Application.get_env(:tymeslot, :enforce_legal_agreements, false)
      end
      """
      |> to_source_file("lib/tymeslot/billing.ex")
      |> run_check(NoSaasReferenceInCore)
      |> refute_issues()
    end

    test "accepts the identical SaaS-referencing code inside the SaaS repo's own tree" do
      """
      defmodule TymeslotSaas.Billing do
        alias TymeslotSaas.Plans

        def plan, do: Application.get_env(:tymeslot_saas, :plan)
      end
      """
      |> to_source_file("lib/tymeslot_saas/billing.ex")
      |> run_check(NoSaasReferenceInCore)
      |> refute_issues()
    end
  end
end
