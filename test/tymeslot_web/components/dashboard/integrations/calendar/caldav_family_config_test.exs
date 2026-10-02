defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavFamilyConfigTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavFamilyConfig

  defp render_form(provider) do
    html =
      render_component(&CaldavFamilyConfig.render/1, %{
        id: CaldavFamilyConfig.component_id(provider),
        provider: provider,
        target: "parent-target",
        myself: "self-target",
        saving: false,
        form_values: %{},
        form_errors: %{},
        show_calendar_selection: false,
        discovered_calendars: [],
        discovery_credentials: %{}
      })

    {html, Floki.parse_document!(html)}
  end

  # Each row: the provider, its root DOM id, heading, guide slug and server
  # placeholder (nil for a fixed host).
  @providers [
    {:caldav, "caldav-config-caldav-config", "CalDAV", "caldav", "https://caldav.example.com"},
    {:nextcloud, "nextcloud-config-nextcloud-config", "Nextcloud", "caldav-nextcloud",
     "https://cloud.example.com"},
    {:radicale, "radicale-config-radicale-config", "Radicale", "caldav-radicale",
     "https://radicale.example.com:5232"},
    {:baikal, "baikal-config-baikal-config", "Baikal", "caldav-baikal",
     "https://baikal.example.com/dav.php"},
    {:zimbra, "zimbra-config-zimbra-config", "Zimbra", "caldav-zimbra",
     "https://mail.example.com"},
    {:mailbox_org, "mailbox-org-config-mailbox-org-config", "mailbox.org", "caldav-mailbox-org",
     nil},
    {:apple, "apple-config-apple-config", "Apple iCloud", "caldav-apple", nil}
  ]

  test "covers exactly the CalDAV-family providers" do
    assert Enum.sort(CaldavFamilyConfig.providers()) ==
             @providers |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  for {provider, dom_id, title, slug, placeholder} <- @providers do
    describe "#{provider}" do
      test "keeps its DOM id, heading, setup guide and provider field" do
        {_html, doc} = render_form(unquote(provider))

        assert [_root] = Floki.find(doc, "div##{unquote(dom_id)}")
        assert doc |> Floki.find("h3") |> hd() |> Floki.text() =~ unquote(title)

        assert [href] =
                 Floki.attribute(
                   doc,
                   "a[target='_blank'][href$='/docs/#{unquote(slug)}']",
                   "href"
                 )

        assert href =~ "/docs/#{unquote(slug)}"

        assert [_field] =
                 Floki.find(
                   doc,
                   "input[type='hidden'][name='integration[provider]'][value='#{unquote(provider)}']"
                 )
      end

      if placeholder do
        test "asks for its server address" do
          {_html, doc} = render_form(unquote(provider))

          assert [_url] = Floki.find(doc, "input[placeholder='#{unquote(placeholder)}']")
          refute Floki.text(doc) =~ "the address cannot be changed"
        end
      else
        test "shows its fixed server address instead of asking for one" do
          {html, _doc} = render_form(unquote(provider))

          url =
            ProviderConfig.locked_url_for(unquote(provider)).url

          assert html =~ ~s(value="#{url}")
        end
      end
    end
  end

  describe "password hints" do
    test "Nextcloud, mailbox.org and iCloud each say where to make an app password" do
      {nextcloud, _doc} = render_form(:nextcloud)
      assert nextcloud =~ "Create an app password in Nextcloud under"

      {mailbox_org, _doc} = render_form(:mailbox_org)
      assert mailbox_org =~ "application-specific password under"

      {apple, _doc} = render_form(:apple)
      assert apple =~ "iCloud will not accept your Apple ID password here."
    end

    test "servers that take an ordinary login show no app-password hint" do
      for provider <- [:caldav, :radicale, :baikal, :zimbra] do
        {html, _doc} = render_form(provider)

        refute html =~ "app password", "#{provider} shows an app-password hint"
        refute html =~ "application-specific password", "#{provider} shows an app-password hint"
      end
    end
  end
end
