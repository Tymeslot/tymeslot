defmodule TymeslotWeb.Dashboard.Automation.PausedCardsTest do
  # While the owner's plan doesn't include automations every automation card
  # renders paused, in the owner's language: a neutral "Paused" pill, a notice
  # saying an upgrade resumes it, and its toggle, edit and test controls shown
  # but inert. Delete stays available. Each integration here is active, so the
  # pill and the controls can only come from the `paused` flag.
  use TymeslotWeb.ConnCase, async: true

  @moduletag :automation
  @moduletag :components

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Dashboard.Automation.{SlackCard, TelegramCard, WebhookCard}

  @handlers %{
    time_format: "24h",
    target: "#automation",
    on_edit: "edit",
    on_delete: "delete",
    on_toggle: "toggle",
    on_test: "test",
    on_view_deliveries: "logs",
    on_disconnect: "disconnect"
  }

  @webhook_notice "Pausiert: Ihr Tarif umfasst keine Automatisierungen. " <>
                    "Nach einem Upgrade läuft der Webhook automatisch weiter."

  @chat_notice "Pausiert: Ihr Tarif umfasst keine Automatisierungen. " <>
                 "Nach einem Upgrade läuft die Integration automatisch weiter."

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "de")
    :ok
  end

  defp webhook do
    %{
      id: 1,
      name: "Buchungen",
      url: "https://example.com/hook",
      is_active: true,
      events: ["meeting.created"],
      last_triggered_at: nil,
      last_status: nil,
      disabled_reason: nil
    }
  end

  defp cards do
    [
      %{
        render: &WebhookCard.webhook_card/1,
        assigns: %{webhook: webhook()},
        toggle: "#webhook-toggle-1",
        edit: "Webhook bearbeiten",
        notice: @webhook_notice
      },
      %{
        render: &SlackCard.slack_card/1,
        assigns: %{integration: build(:slack_integration, id: 1, name: "Buchungen")},
        toggle: "#slack-toggle-1",
        edit: "Bearbeiten",
        notice: @chat_notice
      },
      %{
        render: &TelegramCard.telegram_card/1,
        assigns: %{
          integration:
            build(:telegram_integration,
              id: 1,
              name: "Buchungen",
              bot_mode: "shared",
              status: :active
            )
        },
        toggle: "#telegram-toggle-1",
        edit: "Bearbeiten",
        notice: @chat_notice
      }
    ]
  end

  defp render_card(card, paused) do
    card.render
    |> render_component(@handlers |> Map.merge(card.assigns) |> Map.put(:paused, paused))
    |> LazyHTML.from_fragment()
  end

  defp one!(doc, selector) do
    node = LazyHTML.query(doc, selector)
    assert Enum.count(node) == 1, "expected exactly one #{selector}"
    node
  end

  defp button_labelled!(doc, label), do: one!(doc, ~s(button[aria-label="#{label}"]))

  defp footer_button!(doc, text) do
    [button] =
      doc
      |> LazyHTML.query("[data-part='footer'] button")
      |> Enum.filter(&(&1 |> LazyHTML.text() |> String.trim() == text))

    button
  end

  defp disabled?(node), do: LazyHTML.attribute(node, "disabled") != []
  defp clickable?(node), do: LazyHTML.attribute(node, "phx-click") != []

  defp pill_texts(doc) do
    doc
    |> LazyHTML.query("span.rounded-token-full")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "a paused card" do
    test "shows the translated Paused pill in the neutral tone and the plan notice" do
      for card <- cards() do
        doc = render_card(card, true)

        assert "Pausiert" in pill_texts(doc)
        refute "Aktiv" in pill_texts(doc)
        refute "Verbunden" in pill_texts(doc)

        [pill] =
          doc
          |> LazyHTML.query("span.rounded-token-full")
          |> Enum.filter(&(&1 |> LazyHTML.text() |> String.trim() == "Pausiert"))

        assert pill |> LazyHTML.attribute("class") |> hd() =~ "bg-tymeslot-100"

        notice = one!(doc, "[data-part='notice']")
        assert notice |> LazyHTML.text() |> String.trim() == card.notice
        assert LazyHTML.attribute(notice, "data-tone") == ["neutral"]
      end
    end

    test "renders the toggle, edit and test controls disabled and inert" do
      for card <- cards() do
        doc = render_card(card, true)

        for control <- [
              one!(doc, card.toggle),
              button_labelled!(doc, card.edit),
              footer_button!(doc, "Testen")
            ] do
          assert disabled?(control)
          refute clickable?(control)
        end
      end
    end

    test "keeps delete enabled" do
      for card <- cards() do
        delete = card |> render_card(true) |> button_labelled!("Buchungen löschen")

        refute disabled?(delete)
        assert LazyHTML.attribute(delete, "phx-click") == ["delete"]
      end
    end

    test "on Slack, disconnecting stays available: the owner can always disconnect" do
      [_webhook, slack, _telegram] = cards()
      disconnect = slack |> render_card(true) |> button_labelled!("Slack trennen")

      refute disabled?(disconnect)
      assert LazyHTML.attribute(disconnect, "phx-click") == ["disconnect"]
    end
  end

  describe "a card under a plan that includes automations" do
    test "keeps its own status and working controls" do
      for card <- cards() do
        doc = render_card(card, false)

        refute "Pausiert" in pill_texts(doc)
        assert Enum.empty?(LazyHTML.query(doc, "[data-part='notice']"))

        for control <- [
              one!(doc, card.toggle),
              button_labelled!(doc, card.edit),
              footer_button!(doc, "Testen")
            ] do
          refute disabled?(control)
          assert clickable?(control)
        end
      end
    end

    test "an auto-disabled webhook still names the recorded reason" do
      doc =
        render_card(
          %{
            render: &WebhookCard.webhook_card/1,
            assigns: %{webhook: %{webhook() | is_active: false, disabled_reason: "HTTP 410"}}
          },
          false
        )

      notice = one!(doc, "[data-part='notice']")
      assert notice |> LazyHTML.text() |> String.trim() == "Deaktiviert: HTTP 410"
      assert LazyHTML.attribute(notice, "data-tone") == ["danger"]
    end
  end
end
