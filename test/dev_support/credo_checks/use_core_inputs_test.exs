Code.require_file(
  "dev_support/credo_checks/html_tags.ex",
  Path.join(__DIR__, "../../..")
)

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

    test "flags a tag whose attributes the formatter has wrapped" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <p>Pick one</p>
          <select
            name="kind"
            phx-change="pick"
          >
            <option>a</option>
          </select>
          """
        end
      end
      '''
      |> check()
      |> assert_issue(fn issue ->
        assert issue.trigger == "<select"
        assert issue.line_no == 5
      end)
    end

    test "flags each wrapped tag on its own line" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <input
            type="text"
            name="a"
          />
          <textarea
            name="b"
          ></textarea>
          """
        end
      end
      '''
      |> check()
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(& &1.line_no) |> Enum.sort() == [4, 8]
      end)
    end

    test "leaves a wrapped hidden input alone" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <input
            name="_csrf_token"
            type="hidden"
            value={@token}
          />
          """
        end
      end
      '''
      |> check()
      |> refute_issues()
    end

    test "reads past a > inside an attribute expression" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <input
            disabled={@count > 1}
            type="hidden"
            name="n"
          />
          """
        end
      end
      '''
      |> check()
      |> refute_issues()
    end

    test "leaves a component of the same name alone" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <.input
            name="q"
            type="text"
          />
          """
        end
      end
      '''
      |> check()
      |> refute_issues()
    end

    test "leaves a tag exempted by a raw-input comment with a reason alone" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <label class="option-card">
            <%!-- raw-input: radio drawn by the option card around it --%>
            <input
              type="radio"
              name="choice"
              class="sr-only"
            />
          </label>
          """
        end
      end
      '''
      |> check()
      |> refute_issues()
    end

    test "flags a tag whose raw-input comment gives no reason" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <%!-- raw-input: --%>
          <input type="radio" name="choice" />
          """
        end
      end
      '''
      |> check()
      |> assert_issue()
    end

    test "an exemption covers only the tag directly below it" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <%!-- raw-input: radio drawn by the option card around it --%>
          <input type="radio" name="a" />
          <input type="radio" name="b" />
          """
        end
      end
      '''
      |> check()
      |> assert_issue(fn issue -> assert issue.line_no == 6 end)
    end

    test "leaves a hidden input whose type is an expression alone" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <input type={"hidden"} name="_csrf_token" value={@token} />
          """
        end
      end
      '''
      |> check()
      |> refute_issues()
    end

    test "leaves a tag inside a HEEx comment alone" do
      ~S'''
      defmodule TymeslotWeb.SomeLive do
        def render(assigns) do
          ~H"""
          <%!-- An earlier version drew a raw
               <select name="unit"> here. --%>
          <.input type="select" name="unit" options={@units} />
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
