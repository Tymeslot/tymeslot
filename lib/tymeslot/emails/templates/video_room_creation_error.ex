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

  Rendered in the owner's locale.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice}
  alias Tymeslot.Integrations.Video.RoomCreationError

  @type integration :: %{
          required(:provider) => atom() | String.t(),
          required(:room_creation_error) => RoomCreationError.code(),
          optional(atom()) => term()
        }

  @doc "The email, addressed and rendered in the recipient's locale."
  @spec render(Tymeslot.Emails.EmailService.user_map(), integration()) :: Email.t()
  def render(user, integration) do
    RecipientLocale.with_user_locale(user, fn ->
      IntegrationNotice.email(user, copy(integration))
    end)
  end

  defp copy(%{room_creation_error: code} = integration) do
    provider = IntegrationLabels.provider_name(integration, :video)

    subject =
      dgettext("emails_integrations", "Bookings on %{provider} are getting no video link",
        provider: provider
      )

    %{
      subject: subject,
      title: dgettext("emails_integrations", "Video rooms not created"),
      preheader: subject,
      subtitle: subject,
      eyebrow: dgettext("emails_integrations", "Integration"),
      reason: RoomCreationError.message(code),
      happening_heading: dgettext("emails_integrations", "What's happening?"),
      happening:
        dgettext(
          "emails_integrations",
          "%{provider} refused to create a video room. Whatever it was for went ahead without one: a booking is still confirmed, and a calendar event is still in your calendar. Nothing on this integration gets a video link until the setting described above changes, and links already sent keep working.",
          provider: provider
        ),
      next_heading: dgettext("emails_integrations", "What should I do?"),
      next:
        dgettext(
          "emails_integrations",
          "Change the setting described above, or ask whoever runs the server to. Once a booking gets its video link again, the notice on your video integration disappears."
        ),
      button: dgettext("emails_integrations", "Open video settings"),
      settings_url: IntegrationLabels.settings_url(:video),
      footer:
        dngettext(
          "emails_integrations",
          "This is the only email you will get about this for now. If the same problem is still there in %{count} day, you will hear about it again. Your video settings show the notice for as long as it lasts.",
          "This is the only email you will get about this for now. If the same problem is still there in %{count} days, you will hear about it again. Your video settings show the notice for as long as it lasts.",
          RoomCreationError.resend_after_days()
        )
    }
  end
end
