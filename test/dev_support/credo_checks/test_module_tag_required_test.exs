Code.require_file(
  "dev_support/credo_checks/test_module_tag_required.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.TestModuleTagRequiredTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.TestModuleTagRequired

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "the filename guard" do
    # Credo reports repo-relative filenames. An earlier guard here matched on
    # "/test/" with leading slash, so it recognised no file Credo ever passed
    # and the check silently approved every test module in both repositories.
    # This is the case that would have caught it.
    test "recognises a test file by its repo-relative path" do
      untagged_module()
      |> to_source_file("test/tymeslot/auth/session_test.exs")
      |> run_check(TestModuleTagRequired)
      |> assert_issue()
    end

    test "recognises a test file by its absolute path" do
      untagged_module()
      |> to_source_file("/home/dev/tymeslot/test/tymeslot/auth/session_test.exs")
      |> run_check(TestModuleTagRequired)
      |> assert_issue()
    end

    test "ignores support files, which are not test modules" do
      """
      defmodule Tymeslot.FactoryTest do
        def build(:user), do: %{}
      end
      """
      |> to_source_file("test/support/factory_test.exs")
      |> run_check(TestModuleTagRequired)
      |> refute_issues()
    end

    test "ignores a module whose name does not end in Test" do
      """
      defmodule Tymeslot.Auth.FakeMailer do
        def deliver(_email), do: :ok
      end
      """
      |> to_source_file("test/tymeslot/auth/session_test.exs")
      |> run_check(TestModuleTagRequired)
      |> refute_issues()
    end
  end

  describe "a domain tag is required" do
    test "accepts a domain tag" do
      tagged_module(["@moduletag :auth"])
      |> run_check(TestModuleTagRequired)
      |> refute_issues()
    end

    test "accepts a domain tag in keyword form" do
      tagged_module(["@moduletag auth: true"])
      |> run_check(TestModuleTagRequired)
      |> refute_issues()
    end

    test "rejects a module carrying only a web-layer tag" do
      tagged_module(["@moduletag :plugs"])
      |> run_check(TestModuleTagRequired)
      |> assert_issue(&assert(&1.message =~ "does not name a domain" or &1.message =~ "domain"))
    end

    test "rejects a module carrying only test-type tags" do
      tagged_module(["@moduletag :unit", "@moduletag :integration"])
      |> run_check(TestModuleTagRequired)
      |> assert_issue()
    end

    test "rejects a module carrying only a special tag" do
      tagged_module(["@moduletag :e2e"])
      |> run_check(TestModuleTagRequired)
      |> assert_issue()
    end

    test "rejects a module with no tag at all" do
      untagged_module()
      |> to_source_file("test/tymeslot/auth/session_test.exs")
      |> run_check(TestModuleTagRequired)
      |> assert_issue()
    end

    test "accepts a domain tag alongside layer, type and unknown tags" do
      tagged_module([
        "@moduletag :live",
        "@moduletag :unit",
        "@moduletag :payments",
        "@moduletag timeout: 120"
      ])
      |> run_check(TestModuleTagRequired)
      |> refute_issues()
    end
  end

  describe "single-expression module bodies" do
    test "a module whose body is one expression is still checked" do
      """
      defmodule Tymeslot.Auth.SessionTest do
        @moduletag :unit
      end
      """
      |> to_source_file("test/tymeslot/auth/session_test.exs")
      |> run_check(TestModuleTagRequired)
      |> assert_issue()
    end
  end

  defp untagged_module do
    """
    defmodule Tymeslot.Auth.SessionTest do
      use Tymeslot.DataCase, async: true

      test "signs a user in" do
        assert true
      end
    end
    """
  end

  defp tagged_module(tags) do
    """
    defmodule Tymeslot.Auth.SessionTest do
      use Tymeslot.DataCase, async: true

    #{Enum.map_join(tags, "\n", &("  " <> &1))}

      test "signs a user in" do
        assert true
      end
    end
    """
    |> to_source_file("test/tymeslot/auth/session_test.exs")
  end
end
