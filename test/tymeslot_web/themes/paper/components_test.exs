defmodule TymeslotWeb.Themes.Paper.ComponentsTest do
  @moduledoc """
  Paper's own pieces, rendered alone: the brand row only when there is a
  logo, the avatar at its sizes, a meeting fact, and the overview's list of
  meeting types with each type's length, price and approval pill, the
  choice marked by `aria-pressed`, and Next held back until one is chosen.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]
  import Tymeslot.Factory

  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Paper.Components
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
  end

  describe "the overview" do
    test "lists each meeting type as a choice, with its length and description" do
      page = overview([])

      assert [row] = Floki.find(page, "button.paper-type[data-testid='duration-option']")
      assert Floki.attribute(row, "data-duration") == ["quick-chat"]
      assert Floki.attribute(row, "aria-pressed") == ["false"]
      assert text([row], ".paper-type__name") == "Quick Chat"
      assert text([row], ".paper-type__duration") == "30 minutes"
      assert text([row], ".paper-type__description") == "A short call"
    end

    test "holds Next back until a type is chosen, and marks the chosen one" do
      assert [_next] = Floki.find(overview([]), "button[data-testid='next-step'][disabled]")

      chosen = overview(selected_duration: "quick-chat")

      assert Floki.find(chosen, "button[data-testid='next-step'][disabled]") == []
      assert [row] = Floki.find(chosen, "button[data-duration='quick-chat']")
      assert Floki.attribute(row, "aria-pressed") == ["true"]
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

    test "says so when there is nothing to book" do
      page = overview(meeting_types: [])

      assert Floki.find(page, "[data-testid='duration-option']") == []
      assert text(page, ".paper-empty") =~ "No meeting types available"
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
end
