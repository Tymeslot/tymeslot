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

  alias Credo.SourceFile
  alias CredoChecks.NoNativeTitle

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp issues(template, filename \\ "lib/tymeslot_web/example.ex", preamble \\ "") do
    """
    defmodule TymeslotWeb.Example do
      #{preamble}
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
  end

  test "a wrapper's global spread can carry the caller's id; another spread cannot" do
    template = ~S|<.action_button tooltip={@tooltip} {@rest}>Go</.action_button>|

    assert [] = issues(template, "lib/tymeslot_web/example.ex", "attr :rest, :global")
    assert [%{trigger: "tooltip="}] = issues(template)

    assert [%{trigger: "tooltip="}] =
             issues(~S|<.action_button tooltip="Reason" {@open_attrs}>Go</.action_button>|)
  end

  test "flags a title forwarded through any component's global attributes" do
    assert [_] = issues(~S|<.input field={@form[:name]} title="Reason" />|)
    assert [_] = issues(~S|<.select id="s" options={[]} title={@reason} />|)
    assert [_] = issues(~S|<CoreComponents.input name="x" value="" title="Reason" />|)
  end

  test "leaves a component with no global attributes alone" do
    assert [] = issues(~S|<.unknown_widget title="Heading" />|)
  end

  describe "forwarding_components/1" do
    test "takes components with a global attribute and no title of their own" do
      source = """
      attr :rest, :global
      def chip(assigns), do: assigns

      attr :title, :string
      attr :rest, :global
      def panel(assigns), do: assigns

      attr :label, :string
      def plain(assigns), do: assigns
      """

      forwarding = NoNativeTitle.forwarding_components([source])

      assert MapSet.member?(forwarding, "chip")
      refute MapSet.member?(forwarding, "panel")
      refute MapSet.member?(forwarding, "plain")
      assert MapSet.member?(forwarding, "link")
    end

    test "leaves a name alone when any component of that name declares a title" do
      forwarding =
        NoNativeTitle.forwarding_components([
          "attr :rest, :global\ndef card(assigns), do: assigns",
          "attr :title, :string\ndef card(assigns), do: assigns"
        ])

      refute MapSet.member?(forwarding, "card")
    end

    test "the real components include the inputs and buttons, not the headings" do
      forwarding =
        NoNativeTitle.forwarding_components(Enum.map(Path.wildcard("lib/**/*.ex"), &File.read!/1))

      for name <- ~w(input select action_button icon_button loading_button icon pill) do
        assert MapSet.member?(forwarding, name), "expected #{name} to forward a title"
      end

      for name <- ~w(card confirm_modal section_header empty_state) do
        refute MapSet.member?(forwarding, name), "expected #{name} to keep its title"
      end
    end
  end

  # Credo reads no `.heex` file, so the templates are checked here instead.
  test "every .heex template under lib/ passes" do
    files = Path.wildcard("lib/**/*.heex")
    assert files != []

    offenders =
      Enum.flat_map(files, fn file ->
        file
        |> File.read!()
        |> SourceFile.parse(file)
        |> NoNativeTitle.run([])
      end)

    assert offenders == []
  end

  test "the .heex sweep finds a title in a template" do
    source = SourceFile.parse(~S|<span title="Reason">x</span>|, "lib/example.html.heex")

    assert [_] = NoNativeTitle.run(source, [])
  end
end
