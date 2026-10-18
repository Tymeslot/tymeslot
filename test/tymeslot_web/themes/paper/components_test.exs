defmodule TymeslotWeb.Themes.Paper.ComponentsTest do
  @moduledoc """
  Paper's own pieces, rendered alone: the brand row only when there is a
  logo, the avatar at its sizes, a meeting fact, and the overview: the
  introduction in the left pane, then in the right pane the list of meeting
  types with each type's length, locations, price and approval pill, the
  choice marked by `aria-current`, and Next held back until one is chosen;
  and the confirmation's duration badge.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Paper.Components
  alias TymeslotWeb.Themes.Paper.Scheduling.Components.ConfirmationComponent
  alias TymeslotWeb.Themes.Paper.Scheduling.Components.OverviewComponent

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp doc(html), do: Floki.parse_fragment!(html)

  defp overview(overrides) do
    assigns =
      Map.merge(
        %{
          id: "paper-overview",
          locale: "en",
          current_state: :overview,
          moment: :overview,
          moment_state: :current,
          organizer_profile: build(:profile, full_name: "Ada Lovelace", username: "ada"),
          username_context: "ada",
          meeting_types: [quick_chat()],
          selected_duration: nil,
          theme_tokens: nil,
          host_currency: nil
        },
        Map.new(overrides)
      )

    OverviewComponent |> render_component(assigns) |> doc()
  end

  defp quick_chat(attrs \\ []) do
    build(
      :meeting_type,
      Keyword.merge(
        [
          name: "Quick Chat",
          slug: "quick-chat",
          duration_minutes: 30,
          description: "A short call"
        ],
        attrs
      )
    )
  end

  defp text(doc, selector), do: doc |> Floki.find(selector) |> Floki.text() |> String.trim()

  defp location_labels(row) do
    row
    |> Floki.find("[data-testid='paper-type-location']")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  describe "brand/1" do
    test "shows the organiser's logo" do
      tokens = %Tokens{media: %{logo: %{src: "/uploads/themes/7/3/images/logo.png"}}}

      html = render_component(&Components.brand/1, theme_tokens: tokens)

      assert [img] = Floki.find(doc(html), ".paper-brand img.paper-logo")
      assert Floki.attribute(img, "src") == ["/uploads/themes/7/3/images/logo.png"]
    end

    test "renders nothing without a logo, or without tokens" do
      assert String.trim(render_component(&Components.brand/1, theme_tokens: %Tokens{})) == ""
      assert String.trim(render_component(&Components.brand/1, theme_tokens: nil)) == ""
    end
  end

  describe "avatar/1" do
    test "draws the organiser's picture at the size asked for" do
      html =
        render_component(&Components.avatar/1,
          profile: build(:profile, full_name: "Ada Lovelace"),
          size: :lg
        )

      assert [_img] = Floki.find(doc(html), "img.paper-avatar.paper-avatar--lg")
    end
  end

  describe "fact/1" do
    test "is a list item holding its icon and its text" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ul>
          <Components.fact icon="hero-clock">30 minutes</Components.fact>
        </ul>
        """)

      assert [fact] = Floki.find(doc(html), "li.paper-fact")
      assert Floki.find(fact, ".paper-fact__icon") != []
      assert text([fact], ".paper-fact__text") == "30 minutes"
    end

    test "is a span where it sits inside a button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Components.fact tag="span" icon="hero-clock">30 minutes</Components.fact>
        """)

      assert [fact] = Floki.find(doc(html), "span.paper-fact")
      assert text([fact], ".paper-fact__text") == "30 minutes"
      assert Floki.find(doc(html), "li") == []
    end
  end

  describe "the overview" do
    test "lists each meeting type as a choice, with its length and description" do
      page = overview([])

      assert [row] = Floki.find(page, "button.paper-type[data-testid='duration-option']")
      assert Floki.attribute(row, "data-duration") == ["quick-chat"]
      assert Floki.attribute(row, "aria-current") == []
      assert text([row], ".paper-type__name") == "Quick Chat"
      assert text([row], ".paper-type__duration") == "30 minutes"
      assert text([row], ".paper-type__description") == "A short call"
    end

    test "offers no Next: a row is the way on, and the chosen one stays marked" do
      page = overview([])

      assert Floki.find(page, "[data-testid='next-step']") == []
      assert [row] = Floki.find(page, "button[data-duration='quick-chat']")
      assert Floki.attribute(row, "phx-click") == ["choose_duration"]

      chosen = overview(selected_duration: "quick-chat")

      assert [row] = Floki.find(chosen, "button[data-duration='quick-chat']")
      assert Floki.attribute(row, "aria-current") == ["true"]
    end

    test "shows a paid type's price in the organiser's currency" do
      paid = quick_chat(payment_required: true, price_cents: 4500)

      assert text(overview(meeting_types: [paid], host_currency: "chf"), ".paper-type__price") ==
               "CHF 45.00"

      assert Floki.find(
               overview(meeting_types: [quick_chat()], host_currency: "chf"),
               ".paper-type__price"
             ) ==
               []
    end

    test "marks a type that needs the host's approval" do
      gated = quick_chat(requires_approval: true)

      assert [_pill] =
               Floki.find(
                 overview(meeting_types: [gated]),
                 ".paper-type [data-testid='approval-pill']"
               )
    end

    test "draws each type's locations as facts, with their icons and labels" do
      office = %LocationOption{id: "a", kind: "in_person", label: "The office", position: 0}
      phone = %LocationOption{id: "b", kind: "phone", label: "Ring us", position: 1}

      page =
        overview(
          meeting_types: [
            quick_chat(locations: [phone, office]),
            quick_chat(name: "Walk", slug: "walk", locations: [office])
          ]
        )

      assert [chat, walk] = Floki.find(page, "button.paper-type")

      assert location_labels(chat) == ["The office", "Ring us"]
      assert location_labels(walk) == ["The office"]

      assert [_icon] =
               Floki.find(walk, "[data-testid='paper-type-location'] svg.paper-fact__icon")

      # The length and the location are the same kind of fact, side by side.
      assert [_clock, _office] = Floki.find(walk, ".paper-type__meta .paper-fact")
    end

    test "says so when there is nothing to book, in the pane beside the introduction" do
      page = overview(meeting_types: [])

      assert Floki.find(page, "[data-testid='duration-option']") == []

      assert text(page, ".paper-overview > .paper-choices .paper-empty") =~
               "No meeting types available"
    end

    test "is the schedule step's wide card, the introduction beside the list" do
      page = overview([])

      assert [_card] = Floki.find(page, "section.paper-card.paper-card--wide")
      assert [_intro] = Floki.find(page, ".paper-overview > header.paper-intro h1.paper-title")

      assert [_row] =
               Floki.find(
                 page,
                 ".paper-overview > .paper-choices [data-testid='duration-option']"
               )
    end

    test "opens with the avatar, or with the logo in its place" do
      assert [_avatar] = Floki.find(overview([]), ".paper-intro img.paper-avatar")
      assert Floki.find(overview([]), ".paper-brand") == []

      tokens = %Tokens{media: %{logo: %{src: "/uploads/logo.png"}}}
      with_logo = overview(theme_tokens: tokens)

      assert [_logo] = Floki.find(with_logo, ".paper-brand img.paper-logo")
      assert Floki.find(with_logo, ".paper-intro img.paper-avatar") == []
    end
  end

  defp confirmation(overrides) do
    render_component(
      ConfirmationComponent,
      Map.merge(
        %{
          id: "confirmation-step",
          locale: "en",
          duration: "30-minutes",
          username_context: "hostuser",
          selected_date: "2026-09-10",
          selected_time: "10:00",
          user_timezone: "UTC",
          email: "guest@example.com",
          guest_emails: [],
          name: "Alice",
          organizer_profile: build(:profile, full_name: "Jane Organizer"),
          meeting_type: nil,
          meeting_status: "confirmed",
          meeting_uid: "abc123",
          custom_fields_snapshot: [],
          custom_field_answers: %{},
          is_rescheduling: false,
          theme_tokens: nil
        },
        Map.new(overrides)
      )
    )
  end

  describe "the confirmation" do
    # The badge reads minutes, never the duration slug the flow carries.
    test "without a meeting type, the duration badge shows minutes" do
      html =
        render_component(ConfirmationComponent, %{
          id: "confirmation-step",
          locale: "en",
          duration: "30-minutes",
          username_context: "hostuser",
          selected_date: "2026-09-10",
          selected_time: "10:00",
          user_timezone: "UTC",
          email: "guest@example.com",
          guest_emails: [],
          name: "Alice",
          organizer_profile: build(:profile, full_name: "Jane Organizer"),
          meeting_type: nil,
          meeting_status: "confirmed",
          meeting_uid: "abc123",
          custom_fields_snapshot: [],
          custom_field_answers: %{},
          is_rescheduling: false,
          theme_tokens: nil
        })

      assert text(doc(html), ".paper-badge") == "30 min"
      refute html =~ "30-minutes"
    end

    test "a reschedule is headed 'Meeting rescheduled'" do
      html = confirmation(is_rescheduling: true)

      assert text(doc(html), "[data-testid='confirmation-heading']") == "Meeting rescheduled"
    end

    test "a request awaiting approval is headed exactly 'Request sent'" do
      html = confirmation(meeting_status: "awaiting_approval")

      assert text(doc(html), "[data-testid='confirmation-heading']") == "Request sent"
    end

    # Paper addresses nobody: each message names the organiser, never the guest.
    for {label, overrides, expected} <- [
          {"a booking", [], "Your meeting with Jane Organizer is confirmed."},
          {"a reschedule", [is_rescheduling: true],
           "Your meeting with Jane Organizer has been rescheduled."},
          {"a request", [meeting_status: "awaiting_approval"],
           "Your request to Jane Organizer has been sent."}
        ] do
      test "says #{label} is settled without the guest's name" do
        html = confirmation(unquote(overrides))

        assert text(doc(html), ".paper-confirmation__message") == unquote(expected)
        refute html =~ "Alice"
      end
    end

    for {label, overrides, expected} <- [
          {"a booking", [], "Your meeting is confirmed."},
          {"a reschedule", [is_rescheduling: true], "Your meeting has been rescheduled."},
          {"a request", [meeting_status: "awaiting_approval"], "Your request has been sent."}
        ] do
      test "says #{label} is settled without an organiser name to give" do
        html = confirmation([organizer_profile: nil] ++ unquote(overrides))

        assert text(doc(html), ".paper-confirmation__message") == unquote(expected)
      end
    end

    test "the way to another booking reads 'Book another meeting'" do
      html = confirmation([])

      assert text(doc(html), "[data-testid='schedule-another']") == "Book another meeting"
    end
  end
end
