Code.require_file(
  "dev_support/credo_checks/use_core_inputs.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.UseCoreInputsTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.UseCoreInputs

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source, filename \\ "lib/tymeslot_web/live/some_live.ex") do
    source
    |> to_source_file(filename)
    |> run_check(UseCoreInputs)
  end

  describe "raw tags" do
    test "flags a raw input in a template" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <input type="text" name="q" />
          """
        end
      end
      '''
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "<input" end)
    end

    test "leaves hidden inputs alone" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <input type="hidden" name="_csrf_token" value={@token} />
          """
        end
      end
      '''
      |> check()
      |> refute_issues()
    end

    test "leaves a comment that mentions a tag alone" do
      """
      defmodule TymeslotWeb.SomeLive do
        # Renders the <select> through the core input component.
        def render(assigns), do: assigns
      end
      """
      |> check()
      |> refute_issues()
    end
  end

  describe "form helpers" do
    test "flags a helper called on its module" do
      """
      defmodule TymeslotWeb.SomeView do
        def field(f), do: PhoenixHTMLHelpers.Form.select(f, :kind, ["a", "b"])
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == ".select" end)
    end

    test "flags a helper called through an alias of its module" do
      """
      defmodule TymeslotWeb.SomeView do
        alias Phoenix.HTML.Form
        def field(f), do: Form.text_input(f, :name)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == ".text_input" end)
    end

    test "flags a helper imported from its module" do
      """
      defmodule TymeslotWeb.SomeView do
        import PhoenixHTMLHelpers.Form
        def field(f), do: checkbox(f, :agreed)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "checkbox" end)
    end

    test "flags a helper called through an alias with other options" do
      """
      defmodule TymeslotWeb.SomeView do
        alias Phoenix.HTML.Form, as: F, warn: false
        def field(f), do: F.number_input(f, :count)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == ".number_input" end)
    end

    test "flags a helper brought in by use PhoenixHTMLHelpers" do
      """
      defmodule TymeslotWeb.SomeView do
        use PhoenixHTMLHelpers
        def field(f), do: textarea(f, :notes)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "textarea" end)
    end

    test "leaves another module's function of the same name alone" do
      """
      defmodule Tymeslot.Pools do
        def names(registry), do: Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
        def rows(query), do: Ecto.Query.select(query, [r], r.id)
      end
      """
      |> check("lib/tymeslot/pools.ex")
      |> refute_issues()
    end

    test "leaves a module named Form that is not a form module alone" do
      """
      defmodule TymeslotWeb.SomeView do
        alias TymeslotWeb.Survey.Form
        def field(f), do: Form.select(f, :answer)
      end
      """
      |> check()
      |> refute_issues()
    end

    test "leaves a comment that mentions a helper alone" do
      """
      defmodule Tymeslot.Pools do
        # Not Phoenix.HTML.Form.select(f, :kind, options): this reads a registry.
        def names(registry), do: registry
      end
      """
      |> check("lib/tymeslot/pools.ex")
      |> refute_issues()
    end
  end
end
