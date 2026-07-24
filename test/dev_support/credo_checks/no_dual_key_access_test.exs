Code.require_file(
  "dev_support/credo_checks/no_dual_key_access.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoDualKeyAccessTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoDualKeyAccess

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged access" do
    test "flags atom-then-string access on the same key" do
      """
      defmodule Tymeslot.Bookings do
        def email(params) do
          params[:email] || params["email"]
        end
      end
      """
      |> to_source_file("lib/tymeslot/bookings.ex")
      |> run_check(NoDualKeyAccess)
      |> assert_issue(fn issue -> assert issue.trigger == "email" end)
    end

    test "flags string-then-atom access on the same key" do
      """
      defmodule Tymeslot.Bookings do
        def name(attrs) do
          attrs["name"] || attrs[:name]
        end
      end
      """
      |> to_source_file("lib/tymeslot/bookings.ex")
      |> run_check(NoDualKeyAccess)
      |> assert_issue(fn issue -> assert issue.trigger == "name" end)
    end
  end

  describe "accepted access" do
    test "accepts a single-type read with a literal fallback" do
      """
      defmodule Tymeslot.Bookings do
        def email(params) do
          params[:email] || "unknown@example.com"
        end
      end
      """
      |> to_source_file("lib/tymeslot/bookings.ex")
      |> run_check(NoDualKeyAccess)
      |> refute_issues()
    end

    test "accepts a fallback to a genuinely different key" do
      """
      defmodule Tymeslot.Bookings do
        def contact(params) do
          params[:email] || params[:phone]
        end
      end
      """
      |> to_source_file("lib/tymeslot/bookings.ex")
      |> run_check(NoDualKeyAccess)
      |> refute_issues()
    end

    test "accepts the same key read from two different maps" do
      """
      defmodule Tymeslot.Bookings do
        def email(params, defaults) do
          params[:email] || defaults["email"]
        end
      end
      """
      |> to_source_file("lib/tymeslot/bookings.ex")
      |> run_check(NoDualKeyAccess)
      |> refute_issues()
    end
  end
end
