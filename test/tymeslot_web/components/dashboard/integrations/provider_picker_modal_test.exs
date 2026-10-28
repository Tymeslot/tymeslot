defmodule TymeslotWeb.Components.Dashboard.Integrations.ProviderPickerModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ProviderPickerModal

  defp render_picker(overrides) do
    assigns =
      Map.merge(
        %{
          id: "calendar-provider-picker",
          show: true,
          title: "Connect a calendar",
          subtitle: "Sync your availability.",
          target: "target",
          groups: []
        },
        overrides
      )

    render_component(&ProviderPickerModal.provider_picker_modal/1, assigns)
  end

  defp entry(provider, opts \\ []) do
    %{
      provider: provider,
      title: Keyword.get(opts, :title, String.capitalize(provider)),
      description: Keyword.get(opts, :description, "#{provider} description"),
      click_event: Keyword.get(opts, :click_event, "connect_provider"),
      connected?: Keyword.get(opts, :connected?, false)
    }
  end

  defp classes_of(doc, selector) do
    doc
    |> Floki.find(selector)
    |> Floki.attribute("class")
    |> Enum.flat_map(&String.split/1)
  end

  test "renders the title and subtitle" do
    html = render_picker(%{})

    assert html =~ "Connect a calendar"
    assert html =~ "Sync your availability."
  end

  test "renders the subtitle as secondary text rather than inheriting the modal heading styles" do
    doc = Floki.parse_document!(render_picker(%{}))

    heading_classes = classes_of(doc, ".modal-title")
    subtitle_classes = classes_of(doc, ".modal-title p")

    # The modal renders its :header slot inside .modal-title, so the heading's
    # weight and tracking cascade onto the subtitle unless it resets them. The
    # heading keeps them: every modal title in the app shares those styles.
    assert "font-black" in heading_classes
    assert "tracking-tight" in heading_classes

    assert "font-normal" in subtitle_classes
    assert "tracking-normal" in subtitle_classes
  end

  test "renders each provider as a selectable button dispatching its click event" do
    groups = [
      %{
        label: nil,
        providers: [entry("google", title: "Google Calendar"), entry("outlook")]
      },
      %{label: "CalDAV servers", providers: [entry("apple"), entry("caldav")]}
    ]

    html = render_picker(%{groups: groups})
    doc = Floki.parse_document!(html)

    assert html =~ "Google Calendar"
    assert html =~ "CalDAV servers"

    for provider <- ~w(google outlook apple caldav) do
      assert Floki.find(
               doc,
               "button[phx-click='connect_provider'][phx-value-provider='#{provider}'][phx-target='target']"
             ) != [],
             "expected a selectable button for #{provider}"
    end
  end

  test "marks already-connected providers" do
    groups = [%{label: nil, providers: [entry("google", connected?: true)]}]

    html = render_picker(%{groups: groups})

    assert html =~ "Connected"
  end

  # A connected card shares its title row with the badge; the title must wrap
  # (and the badge drop below it) rather than be cut to "Custom Video Li…".
  test "a connected provider's title wraps beside its badge instead of truncating" do
    groups = [
      %{label: nil, providers: [entry("custom", title: "Custom Video Link", connected?: true)]}
    ]

    doc = %{groups: groups} |> render_picker() |> Floki.parse_fragment!()

    title_classes = classes_of(doc, "h4")
    refute "truncate" in title_classes
    assert "break-words" in title_classes

    assert [_title] = Floki.find(doc, "div.flex-wrap > h4")
    assert doc |> Floki.find("div.flex-wrap > span") |> Floki.text() =~ "Connected"
  end

  test "renders a provider without a click event as disabled" do
    groups = [%{label: nil, providers: [entry("comingsoon", click_event: nil)]}]

    html = render_picker(%{groups: groups})
    doc = Floki.parse_document!(html)

    # No enabled click handler; the button is disabled instead.
    assert Floki.find(doc, "button[phx-value-provider='comingsoon'][disabled]") != []
    refute html =~ ~s(phx-click="connect_provider")
  end

  test "hides an empty group" do
    groups = [%{label: "CalDAV servers", providers: []}]

    html = render_picker(%{groups: groups})

    refute html =~ "CalDAV servers"
  end
end
