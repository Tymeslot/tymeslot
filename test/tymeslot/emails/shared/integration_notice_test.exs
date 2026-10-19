defmodule Tymeslot.Emails.Shared.IntegrationNoticeTest do
  use ExUnit.Case, async: true

  @moduletag :emails
  @moduletag :integrations

  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice, Sanitise}

  alias Tymeslot.Emails.Templates.{
    IntegrationPaused,
    IntegrationReauthRequired,
    IntegrationUnhealthy
  }

  alias Tymeslot.Locales

  @copy %{
    subject: "Subject",
    title: "Title",
    preheader: "Preheader",
    subtitle: "Subtitle",
    eyebrow: "Integration",
    reason: "Reason",
    happening_heading: "What's happening?",
    happening: "Happening",
    next_heading: "What should I do?",
    next: ["Step"],
    button: "Open settings",
    settings_url: "https://example.com/dashboard/integrations",
    footer: "Footer"
  }

  @user %{id: 1, name: "Alice", email: "alice@example.com"}

  describe "emphasis" do
    test "sets the emphasised part of a sentence in bold in the HTML only" do
      email =
        IntegrationNotice.email(@user, %{@copy | happening: {"Select Edit on the row", "Edit"}})

      assert email.html_body =~ "Select <strong>Edit</strong> on the row"
      assert email.text_body =~ "Select Edit on the row"
    end

    test "renders an empty emphasis as the plain sentence" do
      email = IntegrationNotice.email(@user, %{@copy | happening: {"Nothing to stress", ""}})

      assert email.html_body =~ "Nothing to stress"
      refute email.html_body =~ "<strong></strong>"
    end
  end

  # Bold is set on a substring of a translated sentence. A translation that
  # inflects the emphasised word, or drops it, loses the bold silently; this
  # catches it in every locale.
  describe "every locale" do
    for locale <- Locales.supported_codes() do
      test "keeps every emphasised word in its sentence in #{locale}" do
        locale = unquote(locale)
        user = Map.put(@user, :locale, locale)

        missing =
          for {email, emphases} <- cases(user, locale),
              emphasis <- emphases,
              strong = "<strong>#{Sanitise.sanitize_for_email(emphasis)}</strong>",
              not String.contains?(email.html_body, strong),
              do: {email.subject, emphasis}

        assert missing == []
      end
    end
  end

  defp cases(user, locale) do
    zoom = %{provider: :zoom, sync_error: nil}
    google = %{provider: :google, sync_error: nil}
    talk = %{provider: :nextcloud_talk, sync_error: nil}
    feed = %{provider: :ics_url, sync_error: nil}

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      action = &Gettext.dgettext(TymeslotWeb.Gettext, "emails_integrations", &1)
      name = &IntegrationLabels.integration_name/2

      [
        {IntegrationPaused.render(user, zoom, :video, 14),
         [name.(zoom, :video), action.("Reconnect")]},
        {IntegrationUnhealthy.render(user, google, :calendar), [name.(google, :calendar)]},
        {IntegrationReauthRequired.render(user, zoom, :video),
         [name.(zoom, :video), action.("Reconnect")]},
        {IntegrationReauthRequired.render(user, talk, :video),
         [name.(talk, :video), action.("Edit")]},
        {IntegrationReauthRequired.render(user, feed, :calendar),
         [
           name.(feed, :calendar),
           action.("Delete"),
           IntegrationLabels.provider_name(feed, :calendar)
         ]}
      ]
    end)
  end
end
