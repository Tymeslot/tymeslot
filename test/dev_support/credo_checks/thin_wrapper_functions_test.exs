Code.require_file(
  "dev_support/credo_checks/thin_wrapper_functions.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.ThinWrapperFunctionsTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.ThinWrapperFunctions

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags a single-clause private function forwarding to the same name" do
      """
      defmodule Tymeslot.Items do
        def show(item), do: format_item(item)

        defp format_item(item), do: ItemFormatter.format_item(item)
      end
      """
      |> to_source_file("lib/tymeslot/items.ex")
      |> run_check(ThinWrapperFunctions)
      |> assert_issue(fn issue -> assert issue.trigger == "format_item" end)
    end

    test "flags a safe_ wrapper" do
      """
      defmodule Tymeslot.Secrets do
        def read(value), do: safe_decrypt(value)

        defp safe_decrypt(value), do: Encryption.decrypt(value)
      end
      """
      |> to_source_file("lib/tymeslot/secrets.ex")
      |> run_check(ThinWrapperFunctions)
      |> assert_issue(fn issue -> assert issue.trigger == "safe_decrypt" end)
    end
  end

  describe "accepted cases" do
    test "accepts a multi-clause function dispatching between modules" do
      """
      defmodule TymeslotWeb.Icons do
        def known?(name), do: fetch(name) != :error

        defp fetch("hero-" <> _rest = name), do: Heroicons.fetch(name)
        defp fetch(name) when is_binary(name), do: CustomIcons.fetch(name)
        defp fetch(_name), do: :error
      end
      """
      |> to_source_file("lib/tymeslot_web/icons.ex")
      |> run_check(ThinWrapperFunctions)
      |> refute_issues()
    end

    test "accepts a forwarding clause followed by a multi-line clause" do
      """
      defmodule Tymeslot.Items do
        defp format_item(nil), do: ItemFormatter.format_item(:empty)

        defp format_item(item) do
          item
          |> normalise()
          |> ItemFormatter.format_item()
        end
      end
      """
      |> to_source_file("lib/tymeslot/items.ex")
      |> run_check(ThinWrapperFunctions)
      |> refute_issues()
    end
  end
end
