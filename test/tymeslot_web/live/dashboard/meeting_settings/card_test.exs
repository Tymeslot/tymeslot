defmodule TymeslotWeb.Dashboard.MeetingSettings.CardTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.CustomFields.FieldDefinition
  alias TymeslotWeb.Dashboard.MeetingSettings.Card

  defp build_type(overrides) do
    base = %{
      id: 1,
      name: "Strategy Call",
      duration_minutes: 30,
      icon: "hero-bolt",
      is_active: true,
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
