defmodule TymeslotWeb.Dashboard.Automation.StatusPillsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :automation

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Dashboard.Automation.DeliveryComponents
  alias TymeslotWeb.Dashboard.Automation.SlackCard
  alias TymeslotWeb.Dashboard.Automation.TelegramCard

  @card_assigns %{
    time_format: "24h",
    target: "#automation",
    on_edit: "edit",
    on_delete: "delete",
    on_toggle: "toggle",
    on_test: "test",
    on_view_deliveries: "deliveries"
  }

  # Returns the class of the pill labelled `label` and the class of its dot.
  defp pill(html, label) do
    [pill] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("span.rounded-token-full")
      |> Enum.filter(&(&1 |> LazyHTML.text() |> String.trim() == label))

    dot =
      pill
      |> LazyHTML.query("span[aria-hidden='true']")
      |> LazyHTML.attribute("class")
      |> List.first()

    {pill |> LazyHTML.attribute("class") |> hd(), dot}
  end

  # A DateTime cannot be unquoted into a test name, so disablement is a flag.
  defp slack_overrides(disabled: true), do: [disabled_at: ~U[2026-01-01 00:00:00Z]]
  defp slack_overrides(overrides), do: overrides

  describe "Slack card status pill" do
    for {name, overrides, label, tone, pulses?} <- [
          {"pending OAuth", [channel_id: nil], "Channel needed", "bg-amber-100", true},
          {"active", [], "Active", "bg-green-100", false},
          {"paused", [is_active: false], "Paused", "bg-tymeslot-100", false},
          {"auto-disabled", [disabled: true], "Disabled", "bg-red-100", false}
        ] do
      test "shows a #{name} integration as #{label}" do
        integration = build(:slack_integration, [id: 1] ++ slack_overrides(unquote(overrides)))

        html =
          render_component(
            &SlackCard.slack_card/1,
            Map.put(@card_assigns, :integration, integration)
          )

        {class, dot} = pill(html, unquote(label))

        assert class =~ unquote(tone)
        assert dot =~ "rounded-token-full"
        assert dot =~ "animate-pulse" == unquote(pulses?)
      end
    end
  end

  describe "Telegram card status pill" do
    for {status, label, tone, pulses?} <- [
          {:pending_link, "Awaiting connection", "bg-amber-100", true},
          {:active, "Connected", "bg-green-100", false},
          {:paused, "Paused", "bg-tymeslot-100", false},
          {:auto_disabled, "Disabled", "bg-red-100", false}
        ] do
      test "shows a #{status} integration as #{label}" do
        integration = build(:telegram_integration, id: 1, status: unquote(status))

        html =
          render_component(
            &TelegramCard.telegram_card/1,
            Map.put(@card_assigns, :integration, integration)
          )

        {class, dot} = pill(html, unquote(label))

        assert class =~ unquote(tone)
        assert dot =~ "rounded-token-full"
        assert dot =~ "animate-pulse" == unquote(pulses?)
      end
    end
  end

  describe "delivery response status pill" do
    for {status, tone} <- [
          {200, "bg-green-100"},
          {204, "bg-green-100"},
          {299, "bg-green-100"},
          {199, "bg-red-100"},
          {301, "bg-red-100"},
          {404, "bg-red-100"},
          {500, "bg-red-100"}
        ] do
      test "colours HTTP #{status} with #{tone}" do
        delivery = %{
          id: 1,
          event_type: "meeting.created",
          response_status: unquote(status),
          attempt_count: 1,
          inserted_at: ~U[2026-01-01 12:00:00Z],
          error_message: nil
        }

        html =
          render_component(&DeliveryComponents.delivery_list/1,
            deliveries: [delivery],
            time_format: "24h"
          )

        {class, _dot} = pill(html, Integer.to_string(unquote(status)))
        assert class =~ unquote(tone)
      end
    end
  end
end
