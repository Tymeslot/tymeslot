defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.IntegrationCardTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :integrations
  @moduletag :automation
  @moduletag :components

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.IntegrationCard
  alias TymeslotWeb.Dashboard.Automation.SlackCard
  alias TymeslotWeb.Dashboard.CalendarSettings.Components, as: CalendarComponents

  defp render_card(overrides \\ []) do
    assigns =
      Enum.into(overrides, %{
        id: "42",
        title: "Team Room",
        status: {:success, "Healthy"},
        type_tag: nil,
        summary: "localhost:8080/nextcloud",
        active: true,
        toggle_event: "toggle_integration",
        toggle_id: nil,
        notice: nil,
        notice_tone: :warning,
        tags: [],
        activity: nil,
        muted: false,
        actions?: true
      })

    render_component(
      fn assigns ->
        ~H"""
        <IntegrationCard.integration_card
          id={@id}
          title={@title}
          status={@status}
          type_tag={@type_tag}
          summary={@summary}
          active={@active}
          toggle_event={@toggle_event}
          toggle_id={@toggle_id}
          target="#hub"
          notice={@notice}
          notice_tone={@notice_tone}
          tags={@tags}
        >
          <:icon><span data-testid="tile-icon"></span></:icon>
          <:last_activity :if={@activity} muted={@muted}>{@activity}</:last_activity>
          <:actions :if={@actions?}><button data-testid="lead">Test</button></:actions>
          <:end_actions :if={@actions?}><button data-testid="trail">Delete</button></:end_actions>
        </IntegrationCard.integration_card>
        """
      end,
      assigns
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp classes(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class")

  describe "header" do
    test "renders the title, type tag, summary and status label" do
      html = render_card(type_tag: "CalDAV")

      assert html =~ "Team Room"
      assert html =~ "CalDAV"
      assert html =~ "localhost:8080/nextcloud"
      assert html =~ "Healthy"
    end

    test "omits the type tag when not given" do
      refute render_card(type_tag: nil) =~ "uppercase text-tymeslot-500"
    end

    # The summary truncates from `sm` up, so the full value has to stay
    # reachable once a longer server string overflows it.
    test "exposes the whole summary as the hover title" do
      html = render_card(summary: "organiser@example.com · localhost:8080/nextcloud")

      assert html =~ ~s(title="organiser@example.com · localhost:8080/nextcloud")
    end

    test "renders no summary line, and no empty title, when there is no summary" do
      for summary <- [nil, ""] do
        html = render_card(summary: summary)

        refute html =~ ~s(title=")
        refute html =~ "sm:truncate"
      end
    end

    # On a phone the summary wraps rather than being cut off mid-word.
    test "wraps the summary on a phone and truncates it only from sm up" do
      [class] = render_card() |> doc() |> classes("p[title]")

      assert class =~ "break-words"
      assert class =~ "sm:truncate"
      refute class =~ ~r/(^|\s)truncate/
    end
  end

  describe "status" do
    for {tone, pill, dot, tile} <- [
          {:success, "bg-green-100 text-green-700", "bg-green-500", "bg-turquoise-50"},
          {:warning, "bg-amber-100 text-amber-700", "bg-amber-500", "bg-amber-50"},
          {:danger, "bg-red-100 text-red-700", "bg-red-500", "bg-red-50"},
          {:info, "bg-blue-100 text-blue-700", "bg-blue-500", "bg-blue-50"},
          {:neutral, "bg-tymeslot-100 text-tymeslot-600", "bg-tymeslot-400", "bg-tymeslot-100"}
        ] do
      test "shows a #{tone} status as a #{pill} pill and a #{tile} icon tile" do
        doc = [status: {unquote(tone), "Label"}] |> render_card() |> doc()

        [pill] =
          doc
          |> LazyHTML.query("span.rounded-token-full")
          |> Enum.filter(&(&1 |> LazyHTML.text() |> String.trim() == "Label"))

        assert pill |> LazyHTML.attribute("class") |> hd() =~ unquote(pill)

        assert [dot_class] =
                 pill |> LazyHTML.query("span[aria-hidden='true']") |> LazyHTML.attribute("class")

        assert dot_class =~ unquote(dot)

        assert [tile] = classes(doc, "div.h-11.w-11")
        assert tile =~ unquote(tile)
      end
    end
  end

  describe "switch" do
    test "pushes the toggle event with the record's id, under a default DOM id" do
      [switch] =
        render_card() |> doc() |> LazyHTML.query("button[role='switch']") |> Enum.to_list()

      assert LazyHTML.attribute(switch, "id") == ["toggle-42"]
      assert LazyHTML.attribute(switch, "phx-click") == ["toggle_integration"]
      assert LazyHTML.attribute(switch, "phx-value-id") == ["42"]
      assert LazyHTML.attribute(switch, "phx-target") == ["#hub"]
      assert LazyHTML.attribute(switch, "aria-checked") == ["true"]
      assert LazyHTML.attribute(switch, "aria-label") == ["Team Room"]
    end

    test "takes a caller's own DOM id" do
      html = render_card(toggle_id: "slack-toggle-42")

      assert html =~ ~s(id="slack-toggle-42")
      refute html =~ ~s(id="toggle-42")
    end

    test "is not rendered without a toggle event" do
      refute render_card(toggle_event: nil) =~ ~s(role="switch")
    end

    test "is off, and the card de-emphasised, while inactive" do
      html = render_card(active: false)

      assert html =~ ~s(aria-checked="false")
      assert html =~ "opacity-70"
      refute render_card(active: true) =~ "opacity-70"
    end
  end

  describe "details" do
    test "renders each tag as a chip" do
      chips =
        [tags: ["meeting.created", "meeting.cancelled"]]
        |> render_card()
        |> doc()
        |> LazyHTML.query("span.rounded-token-lg")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert chips == ["meeting.created", "meeting.cancelled"]
    end

    test "greys the tags out while inactive" do
      [class | _rest] =
        [tags: ["meeting.created"], active: false]
        |> render_card()
        |> doc()
        |> classes("span.rounded-token-lg")

      assert class =~ "bg-tymeslot-100"
      refute class =~ "bg-turquoise-50"
    end

    test "shows the last activity, in grey italics when muted" do
      html = render_card(activity: "Last triggered: today")
      assert html =~ "Last triggered: today"
      refute html =~ "italic"

      assert render_card(activity: "Never triggered", muted: true) =~ "italic text-tymeslot-400"
    end

    test "colours the notice by its tone" do
      assert render_card(notice: "Pick a channel") =~
               ~r/<p class="[^"]*text-amber-700[^"]*">\s*Pick a channel/

      assert render_card(notice: "Disabled: revoked", notice_tone: :danger) =~
               ~r/<p class="[^"]*text-red-600[^"]*">\s*Disabled: revoked/
    end
  end

  describe "footer" do
    test "puts the leading actions first and pushes the trailing ones to the right" do
      doc = doc(render_card())

      [footer] = doc |> LazyHTML.query("div.border-t") |> Enum.to_list()
      assert footer |> LazyHTML.query("[data-testid='lead']") |> Enum.count() == 1

      [trailing] = footer |> LazyHTML.query("div.ml-auto") |> Enum.to_list()
      assert trailing |> LazyHTML.query("[data-testid='trail']") |> Enum.count() == 1
      assert trailing |> LazyHTML.query("[data-testid='lead']") |> Enum.count() == 0
    end

    # The footer wraps as a row instead of stacking one button per line.
    test "wraps rather than stacks" do
      [class] = render_card() |> doc() |> classes("div.border-t")

      assert class =~ "flex-wrap"
      refute class =~ "flex-col"
    end

    test "is not rendered without actions" do
      refute render_card(actions?: false) =~ "border-t"
    end
  end

  describe "as an automation integration" do
    test "a Slack integration shows its status, last activity and actions" do
      integration =
        build(:slack_integration, id: 7, last_triggered_at: ~U[2026-01-08 12:00:00Z])

      html =
        render_component(&SlackCard.slack_card/1,
          integration: integration,
          time_format: "24h",
          target: "#automation",
          on_edit: "edit",
          on_delete: "delete",
          on_toggle: "toggle",
          on_test: "test",
          on_view_deliveries: "deliveries"
        )

      doc = doc(html)

      text = LazyHTML.text(doc)

      assert text =~ "Active"
      assert text =~ "Last triggered: "
      assert text =~ "Test Workspace · #bookings"
      assert doc |> LazyHTML.query("#slack-toggle-7[phx-click='toggle']") |> Enum.count() == 1

      footer = LazyHTML.query(doc, "div.border-t")
      assert footer |> LazyHTML.query("button[phx-click='test']") |> Enum.count() == 1
      assert footer |> LazyHTML.query("button[phx-click='deliveries']") |> Enum.count() == 1
      assert footer |> LazyHTML.query("button[phx-click='edit']") |> Enum.count() == 1
      assert footer |> LazyHTML.query("button[phx-click='delete']") |> Enum.count() == 1
    end
  end

  describe "as a calendar connection" do
    test "a CalDAV connection shows its status, last sync and actions" do
      integration = %{
        id: 12,
        name: "My CalDAV",
        provider: "caldav",
        is_active: true,
        needs_reauth: false,
        calendar_list: [%CalendarEntry{id: "/a/", path: "/a/", name: "A", selected: true}],
        calendar_paths: ["/a/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -120, :second)
      }

      html =
        render_component(&CalendarComponents.calendar_connection_row/1,
          integration: integration,
          health_state: nil,
          myself: "target"
        )

      doc = doc(html)

      text = LazyHTML.text(doc)

      assert text =~ "Healthy"
      assert text =~ "Last synced "
      # The sync time moved out of the summary onto the activity line.
      refute doc |> LazyHTML.query("p[title]") |> LazyHTML.text() =~ "synced"
      assert doc |> LazyHTML.query("#toggle-12") |> Enum.count() == 1

      footer = LazyHTML.query(doc, "div.border-t")
      assert footer |> LazyHTML.query("button[phx-click='manage_calendars']") |> Enum.count() == 1
      assert footer |> LazyHTML.query("button[phx-click='show_reconnect']") |> Enum.count() == 1

      assert footer
             |> LazyHTML.query("div.ml-auto button[phx-target='#delete-calendar-modal']")
             |> Enum.count() == 1
    end
  end
end
