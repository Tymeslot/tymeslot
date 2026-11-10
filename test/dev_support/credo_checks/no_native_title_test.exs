Code.require_file(
  "dev_support/credo_checks/html_tags.ex",
  Path.join(__DIR__, "../../..")
)

Code.require_file(
  "dev_support/credo_checks/no_native_title.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoNativeTitleTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoNativeTitle

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp issues(template, filename \\ "lib/tymeslot_web/example.ex") do
    """
    defmodule TymeslotWeb.Example do
      def render(assigns) do
        ~H\"\"\"
        #{template}
        \"\"\"
      end
    end
    """
    |> to_source_file(filename)
    |> run_check(NoNativeTitle)
  end

  test "flags title on a lowercase HTML element, wrapped or not" do
    assert [_] = issues(~S|<span title={@reason}>x</span>|)

    assert [_] =
             issues(~S"""
             <div
               class="a"
               title={@reason}
             >x</div>
             """)
  end

  test "flags a title forwarded through the button and link components" do
    assert [_] = issues(~S|<.action_button title="x">Save</.action_button>|)
    assert [_] = issues(~S|<Buttons.loading_button title="x">Go</Buttons.loading_button>|)
    assert [_] = issues(~S|<.link href="/x" title="x">Go</.link>|)
    assert [_] = issues(~S|<Feedback.pill title="x">Go</Feedback.pill>|)
  end

  test "leaves component headings alone" do
    assert [] = issues(~S|<.section_card title="Settings">x</.section_card>|)
    assert [] = issues(~S|<.confirm_modal title={@heading} />|)
    assert [] = issues(~S|<Card.card title="Heading">x</Card.card>|)
  end

  test "leaves iframes alone: their title is an accessible name" do
    assert [] = issues(~S|<iframe src="/x" title="Preview"></iframe>|)
  end

  test "ignores title= inside an attribute value" do
    assert [] = issues(~S|<div data-x="a title=b" phx-value={%{title: "t"}}>x</div>|)
  end

  test "ignores an SVG <title> child element" do
    assert [] = issues(~S|<svg role="img"><title>Chart</title></svg>|)
  end

  test "honours a native-title comment with a reason, and only with one" do
    assert [] =
             issues(~S"""
             <%!-- native-title: repeats the text, which can truncate. --%>
             <span title={@value}>{@value}</span>
             """)

    assert [_] =
             issues(~S"""
             <%!-- native-title: --%>
             <span title={@value}>{@value}</span>
             """)
  end

  test "only looks at lib/" do
    assert [] = issues(~S|<span title="x">x</span>|, "test/example_test.exs")
  end

  test "requires an id on an icon_button with a tooltip" do
    assert [%{trigger: "tooltip="}] =
             issues(~S|<.icon_button icon="hero-x" label="Close" tooltip="Reason" />|)

    assert [] =
             issues(~S|<.icon_button id="close" icon="hero-x" label="Close" tooltip="Reason" />|)

    assert [] = issues(~S|<.icon_button icon="hero-x" label="Close" />|)
  end

  test "requires an id on action and loading buttons with a tooltip" do
    assert [%{trigger: "tooltip="}] =
             issues(~S|<.action_button tooltip="Reason">Go</.action_button>|)

    assert [%{trigger: "tooltip="}] =
             issues(~S|<Buttons.loading_button tooltip="Reason">Go</Buttons.loading_button>|)

    assert [] = issues(~S|<.action_button id="go" tooltip="Reason">Go</.action_button>|)
    assert [] = issues(~S|<.action_button tooltip={@tooltip} {@rest}>Go</.action_button>|)
  end
end
