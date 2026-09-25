Code.require_file(
  "dev_support/credo_checks/no_mix_env_in_core_lib.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoMixEnvInCoreLibTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoMixEnvInCoreLib

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags Mix.env/0 called inside a function" do
      """
      defmodule TymeslotWeb.DevController do
        def index(conn, _params) do
          if Mix.env() == :dev do
            render(conn, :dev_index)
          else
            send_resp(conn, 404, "")
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/controllers/dev_controller.ex")
      |> run_check(NoMixEnvInCoreLib)
      |> assert_issue(fn issue -> assert issue.trigger == "Mix.env" end)
    end
  end

  describe "accepted cases" do
    test "accepts Application.compile_env/3 gating a dev-only surface" do
      """
      defmodule TymeslotWeb.Router do
        if Application.compile_env(:tymeslot, :dev_routes, false) do
          def dev_scope?, do: true
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/router.ex")
      |> run_check(NoMixEnvInCoreLib)
      |> refute_issues()
    end

    test "accepts Mix.env/0 inside a Mix task" do
      """
      defmodule Mix.Tasks.Tymeslot.CreateTestAccount do
        use Mix.Task

        def run(_args) do
          if Mix.env() == :dev, do: :ok
        end
      end
      """
      |> to_source_file("lib/mix/tasks/tymeslot.create_test_account.ex")
      |> run_check(NoMixEnvInCoreLib)
      |> refute_issues()
    end
  end
end
