defmodule Tymeslot.Emails.Templates.VideoRoomCreationError do
  @moduledoc """
  MJML email template telling the owner of a video integration that its
  provider refuses to create rooms, so bookings go out without a video link
  until a setting on the provider's side changes.

  The reason and its fix come from
  `Tymeslot.Integrations.Video.RoomCreationError.message/1`, the same words
  the integration's dashboard row shows, so the two cannot drift apart. Unlike
  `Tymeslot.Emails.Templates.IntegrationReauthRequired`, nothing here asks the
  owner to reconnect: the credentials work, and the server refuses the room.

  Rendered in the owner's locale. The caller establishes it with
  `Tymeslot.Emails.RecipientLocale`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Buttons, Callouts, Styles, TemplateHelper, Text}
  alias Tymeslot.Emails.Templates.IntegrationReauthRequired
  alias Tymeslot.Integrations.Video.RoomCreationError
  alias Tymeslot.Utils.UrlBuilder

  @intent :alert

  @type integration :: %{
          required(:provider) => atom() | String.t(),
          required(:room_creation_error) => RoomCreationError.code(),
          optional(atom()) => term()
        }

  @doc "The subject line, in the current locale."
  @spec subject(integration()) :: String.t()
  def subject(integration) do
    dgettext("emails", "Bookings on %{provider} are getting no video link",
      provider: provider_label(integration)
    )
  end

  @doc "Returns `{html_body, text_body}`."
  @spec render_both(integration()) :: {String.t(), String.t()}
  def render_both(integration) do
    copy = copy(integration)
    {render_html(copy), render_text(copy)}
  end

  defp render_html(copy) do
    mjml_content = """
    #{Callouts.alert_box(:alert, copy.reason, title: copy.title)}

    #{Text.title_section(dgettext("emails", "What's happening?"))}

    <mj-text
      font-size="16px"
      color="#{Styles.ink_soft()}"
      line-height="1.5"
      align="left"
      css-class="mobile-text"
    >
      #{copy.happening}
    </mj-text>

    #{Text.divider()}

    #{Text.title_section(dgettext("emails", "What should I do?"))}

    <mj-text color="#{Styles.ink_soft()}" font-size="14px" line-height="1.6">
      #{copy.action}
    </mj-text>

    #{Buttons.action_button(@intent, copy.button, copy.settings_url)}

    #{Text.divider()}

    #{Text.system_footer_note(copy.footer)}
    """

    TemplateHelper.compile_system_template(mjml_content, copy.title, copy.subject,
      intent: @intent,
      eyebrow: dgettext("emails", "Integration"),
      stage_title: copy.title,
      stage_subtitle: copy.subject
    )
  end

  defp render_text(copy) do
    """
    #{copy.title}

    #{copy.reason}

    #{String.upcase(dgettext("emails", "What's happening?"))}
    #{copy.happening}

    #{String.upcase(dgettext("emails", "What should I do?"))}
    #{copy.action}

    #{copy.button}:
    #{copy.settings_url}

    #{copy.footer}
    """
  end

  defp copy(%{room_creation_error: code} = integration) do
    provider = provider_label(integration)

    %{
      title: dgettext("emails", "Video rooms not created"),
      subject: subject(integration),
      reason: RoomCreationError.message(code),
      happening:
        dgettext(
          "emails",
          "%{provider} refused to create a video room. Whatever it was for went ahead without one: a booking is still confirmed, and a calendar event is still in your calendar. Nothing on this integration gets a video link until the setting described above changes, and links already sent keep working.",
          provider: provider
        ),
      action:
        dgettext(
          "emails",
          "Change the setting described above, or ask whoever runs the server to. Once a booking gets its video link again, the notice on your video integration disappears."
        ),
      button: dgettext("emails", "Open video settings"),
      settings_url: UrlBuilder.build_url("/dashboard/settings?tab=video"),
      footer:
        dgettext(
          "emails",
          "This is the only email you will get about this for now. If the same problem is still there in %{days} days, you will hear about it again. Your video settings show the notice for as long as it lasts.",
          days: RoomCreationError.resend_after_days()
        )
    }
  end

  defp provider_label(integration),
    do: IntegrationReauthRequired.provider_label(integration, :video)
end
