defmodule Tymeslot.Emails.Shared.TemplateHelper do
  @moduledoc """
  Helpers for building organiser details and compiling MJML templates.

  Every email opens with an intent-coloured **stage band**. The intent and
  eyebrow are required — the template declares them explicitly, never inferred
  from a title string or a fallback default.
  """

  alias Tymeslot.Emails.Branding
  alias Tymeslot.Emails.Shared.{Layouts, MjmlEmail, Stage}
  alias Tymeslot.Emails.Shared.Styles.Tokens

  use Gettext, backend: TymeslotWeb.Gettext

  @type organizer_details :: %{
          required(:intent) => Tokens.intent(),
          required(:eyebrow) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:email) => String.t() | nil,
          optional(:avatar_url) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:stage_title) => String.t(),
          optional(:stage_subtitle) => String.t()
        }

  @typedoc """
  Permissive shape accepted by `build_organizer_details/2`. Covers both the
  full `Tymeslot.Emails.EmailService.appointment_details()` map used by
  attendee-facing flows and the narrower 4-key map used by the operator
  notification templates (Stripe dispute, Connect-restricted, refund) that
  only carry organiser information.
  """
  @type organizer_source :: %{
          required(:organizer_name) => String.t() | nil,
          required(:organizer_email) => String.t() | nil,
          optional(:organizer_title) => String.t() | nil,
          optional(:organizer_avatar_url) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Builds organiser details from an appointment details map.

  `stage` must include `:intent` and `:eyebrow` — the template declares them.

      TemplateHelper.build_organizer_details(details,
        intent: :confirmed,
        eyebrow: "Confirmed",
        stage_title: "You're booked",
        stage_subtitle: "I'll see you on Tuesday at 15:00"
      )
  """
  @spec build_organizer_details(organizer_source(), keyword()) :: organizer_details()
  def build_organizer_details(appointment_details, stage) do
    Stage.fetch_required!(stage, :intent)
    Stage.fetch_required!(stage, :eyebrow)

    base = %{
      name: appointment_details.organizer_name,
      email: appointment_details.organizer_email,
      avatar_url: Map.get(appointment_details, :organizer_avatar_url),
      title: appointment_details.organizer_title || Branding.brand_name()
    }

    Enum.reduce(stage, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  @doc "Compiles MJML content with organiser details into HTML."
  @spec compile_template(String.t(), organizer_details()) :: String.t()
  def compile_template(mjml_content, organizer_details) do
    mjml_content
    |> Layouts.transactional_layout(organizer_details)
    |> MjmlEmail.compile_mjml()
  end

  @doc """
  Compiles MJML content for system emails into HTML.

  `stage` must include `:intent` and `:eyebrow`. Optional keys: `:stage_title`,
  `:stage_subtitle`.
  """
  @spec compile_system_template(String.t(), String.t(), String.t() | nil, keyword()) ::
          String.t()
  def compile_system_template(mjml_content, title, preview, stage) do
    Stage.fetch_required!(stage, :intent)
    Stage.fetch_required!(stage, :eyebrow)

    opts =
      [title: title]
      |> maybe_put(:preview, preview)
      |> Keyword.merge(stage)

    mjml_content
    |> Layouts.system_layout(opts)
    |> MjmlEmail.compile_mjml()
  end

  @typedoc """
  The meeting as one recipient reads it, handed unchanged to both the HTML card
  (`Tymeslot.Emails.Shared.MeetingComponents.meeting_details_table/2`) and the
  plain-text body (`Tymeslot.Emails.Shared.TextBodyHelper.format_meeting_details/2`),
  so the two parts of an email state the same time in the same zone.
  """
  @type meeting_details :: %{
          required(:date) => Date.t() | DateTime.t(),
          required(:start_time) => DateTime.t() | nil,
          required(:duration) => integer() | nil,
          required(:location) => String.t() | nil,
          required(:location_type) => atom() | nil,
          required(:meeting_type) => String.t() | nil,
          optional(:time_format) => String.t() | nil,
          optional(:audience) => :host | :guest,
          optional(:all_day) => boolean(),
          optional(:last_date) => Date.t() | nil
        }

  @doc """
  The meeting-details map for the booker (`:attendee`) or a guest the booker
  invited (`:guest`): the meeting in the booker's timezone, on the clock their
  locale uses. A guest's map is marked `audience: :guest`, which words the
  details for them rather than for the booker; the booker's carries no
  audience, the default wording.
  """
  @spec attendee_meeting_details(map(), :attendee | :guest) :: meeting_details()
  def attendee_meeting_details(appointment_details, audience)
      when audience in [:attendee, :guest] do
    appointment_details
    |> shared_meeting_details(appointment_details.start_time_attendee_tz)
    |> put_audience(audience)
  end

  @doc """
  The meeting-details map for an organiser-addressed render: the meeting as the
  organiser sees it, in their own timezone and on the clock they chose.

  The payload is built once and rendered for every recipient, so the
  organiser's clock travels under `:organizer_time_format`, where a render for
  the booker cannot mistake it for its own; this is the only place it becomes
  the map's `:time_format`. The map is marked as the host's (`audience: :host`),
  which words the details for them.
  """
  @spec organizer_meeting_details(map()) :: meeting_details()
  def organizer_meeting_details(appointment_details) do
    appointment_details
    |> shared_meeting_details(appointment_details.start_time_owner_tz)
    |> Map.merge(%{
      time_format: Map.get(appointment_details, :organizer_time_format),
      audience: :host
    })
  end

  # The date is the recipient's: the payload's `:date` is the start's UTC
  # day, which is a different day wherever the meeting starts before or after
  # midnight UTC. An all-day event's days are calendar days in no zone, so it
  # keeps them.
  defp shared_meeting_details(appointment_details, start_time) do
    appointment_details
    |> Map.take([:all_day, :last_date])
    |> Map.merge(%{
      date: recipient_date(appointment_details, start_time),
      start_time: start_time,
      duration: appointment_details.duration,
      location: appointment_details.location,
      location_type: Map.get(appointment_details, :location_type),
      meeting_type: appointment_details.meeting_type
    })
  end

  defp recipient_date(%{all_day: true, date: date}, _start_time), do: date

  defp recipient_date(_appointment_details, %DateTime{} = start_time),
    do: DateTime.to_date(start_time)

  defp recipient_date(appointment_details, _start_time), do: appointment_details.date

  defp put_audience(meeting_details, :guest), do: Map.put(meeting_details, :audience, :guest)
  defp put_audience(meeting_details, :attendee), do: meeting_details

  @doc """
  A guest's answer actions, for `MeetingComponents.actions_section/4`: attend
  or decline, each with the payload's link for it. An answer without a
  linkable URL is left out when rendered; the plain-text counterpart is
  `TextBodyHelper.format_guest_answers/3`.
  """
  @spec guest_answer_actions(map()) :: [map()]
  def guest_answer_actions(appointment_details) do
    [
      %{
        text: dgettext("emails_booking", "Yes, I'll attend"),
        url: Map.get(appointment_details, :guest_accept_url),
        style: :secondary
      },
      %{
        text: dgettext("emails_booking", "Can't make it"),
        url: Map.get(appointment_details, :guest_decline_url),
        style: :danger
      }
    ]
  end

  @doc "Formats error reasons for display in templates."
  @spec format_error_reason(any()) :: String.t()
  def format_error_reason(reason) when is_binary(reason), do: reason
  def format_error_reason(reason), do: inspect(reason)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
