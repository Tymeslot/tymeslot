defmodule Tymeslot.Emails.Shared.TemplateHelper do
  @moduledoc """
  Helpers for building organiser details and compiling MJML templates.

  Every email opens with an intent-coloured **stage band**. The intent and
  eyebrow are required — the template declares them explicitly, never inferred
  from a title string or a fallback default.
  """

  alias Tymeslot.Emails.Shared.{AvatarHelper, Layouts, MjmlEmail}
  alias Tymeslot.Emails.Shared.Styles.Tokens

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
    fetch_required!(stage, :intent)
    fetch_required!(stage, :eyebrow)

    base = %{
      name: appointment_details.organizer_name,
      email: appointment_details.organizer_email,
      avatar_url: AvatarHelper.generate_avatar_url(appointment_details),
      title: appointment_details.organizer_title || "Tymeslot"
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
    fetch_required!(stage, :intent)
    fetch_required!(stage, :eyebrow)

    opts =
      [title: title]
      |> maybe_put(:preview, preview)
      |> Keyword.merge(stage)

    mjml_content
    |> Layouts.system_layout(opts)
    |> MjmlEmail.compile_mjml()
  end

  @doc """
  Rewrites a shared appointment payload for an organiser-addressed render.

  The payload is built once and rendered twice, for the attendee and for the
  organiser, so the organiser's clock travels under `:organizer_time_format`
  where an attendee render cannot mistake it for its own. Promoting it to the
  generic `:time_format` key here marks the point where the audience is known,
  and is the only place that promotion happens.
  """
  @spec as_organizer_view(map()) :: map()
  def as_organizer_view(appointment_details) do
    Map.put(
      appointment_details,
      :time_format,
      Map.get(appointment_details, :organizer_time_format)
    )
  end

  @doc """
  The meeting-details map for an organiser-addressed render: the meeting as the
  organiser sees it, in their own timezone and on the clock they chose.

  Three templates (confirmation, cancellation, reminder) render the same block
  from the same payload, so the shape lives here once. Two copies of "which
  fields the organiser's meeting card shows" is exactly where a new field gets
  added to one and forgotten in the other.
  """
  @spec organizer_meeting_details(map()) :: map()
  def organizer_meeting_details(appointment_details) do
    %{
      date: appointment_details.date,
      start_time: appointment_details.start_time_owner_tz,
      duration: appointment_details.duration,
      location: appointment_details.location,
      location_type: Map.get(appointment_details, :location_type),
      meeting_type: appointment_details.meeting_type,
      time_format: Map.get(appointment_details, :organizer_time_format)
    }
  end

  @doc "Formats error reasons for display in templates."
  @spec format_error_reason(any()) :: String.t()
  def format_error_reason(reason) when is_binary(reason), do: reason
  def format_error_reason(reason), do: inspect(reason)

  @spec fetch_required!(keyword(), atom()) :: term()
  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "Tymeslot.Emails.Shared.TemplateHelper: missing required stage option `#{inspect(key)}`. " <>
                "Templates must declare `:intent` and `:eyebrow` at the call site."
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
