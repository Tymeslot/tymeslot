defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponentsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :integrations

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents

  defp render_actions(assigns) do
    html = render_component(&UIComponents.form_actions/1, Map.new(assigns))
    {html, Floki.parse_document!(html)}
  end

  describe "form_actions/1" do
    test "Cancel goes back to the provider list on the given target" do
      {_html, doc} = render_actions(target: "#calendar-settings")

      [cancel] = Floki.find(doc, "button[type='button']")

      assert Floki.attribute(cancel, "phx-click") == ["back_to_providers"]
      assert Floki.attribute(cancel, "phx-target") == ["#calendar-settings"]
      assert Floki.text(cancel) =~ "Cancel"
    end

    test "Cancel pushes a caller's own event" do
      {_html, doc} = render_actions(target: "#t", cancel_event: "close_form")

      assert Floki.attribute(doc, "button[type='button']", "phx-click") == ["close_form"]
    end

    test "submit reads Add Integration by default" do
      {_html, doc} = render_actions(target: "#t")

      [submit] = Floki.find(doc, "button[type='submit']")
      assert String.trim(Floki.text(submit)) == "Add Integration"
      assert Floki.attribute(submit, "disabled") == []
    end

    test "submit shows the caller's text, and its saving text while saving" do
      {_html, doc} =
        render_actions(target: "#t", submit_text: "Subscribe", saving_text: "Subscribing...")

      assert doc |> Floki.find("button[type='submit']") |> Floki.text() |> String.trim() ==
               "Subscribe"

      {_html, saving_doc} =
        render_actions(
          target: "#t",
          saving: true,
          submit_text: "Subscribe",
          saving_text: "Subscribing..."
        )

      [submit] = Floki.find(saving_doc, "button[type='submit']")
      assert Floki.text(submit) =~ "Subscribing..."
      refute Floki.text(submit) =~ "Subscribe"
      assert Floki.attribute(submit, "disabled") != []
    end

    test "saving falls back to Adding..." do
      {_html, doc} = render_actions(target: "#t", saving: true)

      assert doc |> Floki.find("button[type='submit']") |> Floki.text() =~ "Adding..."
    end

    test "class sets the divider colour, defaulting to the neutral border" do
      {default_html, _doc} = render_actions(target: "#t")
      {calendar_html, _doc} = render_actions(target: "#t", class: "border-turquoise-200/30")

      assert default_html =~
               ~s(class="flex justify-between items-center pt-4 border-t border-tymeslot-100")

      assert calendar_html =~
               ~s(class="flex justify-between items-center pt-4 border-t border-turquoise-200/30")
    end
  end

  describe "provider_config_header/1" do
    defp render_header(assigns) do
      html =
        render_component(
          &UIComponents.provider_config_header/1,
          Enum.into(assigns, %{
            provider: "nextcloud",
            type: "calendar",
            title: "Nextcloud",
            tagline: "Sync calendars from your Nextcloud server"
          })
        )

      {html, Floki.parse_document!(html)}
    end

    test "shows the provider's icon, name and tagline" do
      {_html, doc} = render_header([])

      assert [src] = Floki.attribute(doc, "img", "src")
      assert src =~ "/icons/providers/calendar/"
      assert src =~ "nextcloud"
      assert doc |> Floki.find("h3") |> Floki.text() == "Nextcloud"

      assert doc |> Floki.find("h3 + p") |> Floki.text() ==
               "Sync calendars from your Nextcloud server"
    end

    test "links the setup guide in a new tab when given a slug" do
      {_html, doc} = render_header(guide_slug: "caldav-nextcloud")

      assert [link] = Floki.find(doc, "a")
      assert Floki.attribute(link, "href") == ["https://tymeslot.app/docs/caldav-nextcloud"]
      assert Floki.attribute(link, "target") == ["_blank"]
      assert Floki.attribute(link, "rel") == ["noopener noreferrer"]
      assert Floki.text(link) =~ "Setup guide"
    end

    test "has no guide link without a slug" do
      {_html, doc} = render_header(type: "video", provider: "mirotalk", title: "MiroTalk P2P")

      assert Floki.find(doc, "a") == []
    end

    test "uses the type scale tokens rather than raw sizes" do
      {html, _doc} = render_header([])

      assert html =~ "text-token-lg"
      assert html =~ "text-token-sm"
      refute html =~ ~r/class="[^"]*\btext-(lg|sm)\b/
    end
  end
end
