defmodule TymeslotWeb.Dashboard.MeetingSettings.CardTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :meeting_types

  import Phoenix.LiveViewTest

  alias Tymeslot.CustomFields.FieldDefinition
  alias TymeslotWeb.Dashboard.MeetingSettings.Card

  defp build_type(overrides) do
    base = %{
      id: 1,
      name: "Strategy Call",
      description: nil,
      duration_minutes: 30,
      icon: "hero-bolt",
      is_active: true,
      is_private: false,
      allow_video: false,
      payment_required: false,
      price_cents: nil,
      custom_fields: [],
      video_integration: nil,
      calendar_integration: nil,
      target_calendar_id: nil
    }

    Map.merge(base, overrides)
  end

  defp render_card(type, assigns \\ %{}) do
    render_component(
      &Card.meeting_type_card/1,
      Map.merge(%{type: type, myself: %Phoenix.LiveComponent.CID{cid: 1}}, assigns)
    )
  end

  describe "paid token" do
    test "renders the formatted price for a paid meeting type" do
      html =
        render_card(build_type(%{payment_required: true, price_cents: 900}), %{currency: "eur"})

      assert html =~ "€9.00"
    end

    test "is omitted when the meeting type is free" do
      html = render_card(build_type(%{payment_required: false, price_cents: nil}))

      refute html =~ "€"
      refute html =~ "hero-banknotes-mini"
    end

    test "is omitted when payment is required but no price is set" do
      html = render_card(build_type(%{payment_required: true, price_cents: nil}))

      refute html =~ "hero-banknotes-mini"
    end
  end

  describe "description" do
    defp description_paragraphs(html) do
      html
      |> Floki.parse_fragment!()
      |> Floki.find("p")
    end

    defp description_text(html) do
      html |> description_paragraphs() |> Floki.text() |> String.trim()
    end

    test "renders the description below the title and above the duration" do
      html = render_card(build_type(%{description: "A quick chat about your roadmap."}))

      assert description_text(html) == "A quick chat about your roadmap."

      assert Regex.match?(
               ~r/Strategy Call.*A quick chat about your roadmap\..*30 min/s,
               Floki.text(Floki.parse_fragment!(html))
             )
    end

    test "escapes HTML in the description" do
      html = render_card(build_type(%{description: "<script>alert(1)</script>"}))

      refute html =~ "<script>"
      assert description_text(html) == "<script>alert(1)</script>"
    end

    test "is omitted when the meeting type has no description" do
      html = render_card(build_type(%{description: nil}))

      assert html =~ "Strategy Call"
      assert description_paragraphs(html) == []
    end

    test "is omitted when the description is only whitespace" do
      html = render_card(build_type(%{description: "   \n  "}))

      assert description_paragraphs(html) == []
    end
  end

  describe "custom questions token" do
    test "pluralises the count when there are multiple questions" do
      html = render_card(build_type(%{custom_fields: [%FieldDefinition{}, %FieldDefinition{}]}))

      assert html =~ "+2 custom questions"
    end

    test "uses the singular form for a single question" do
      html = render_card(build_type(%{custom_fields: [%FieldDefinition{}]}))

      assert html =~ "+1 custom question"
      refute html =~ "+1 custom questions"
    end

    test "is omitted when there are no custom questions" do
      html = render_card(build_type(%{custom_fields: []}))

      refute html =~ "custom question"
    end
  end
end
