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
  @spec build_organizer_details(
          Tymeslot.Emails.EmailService.appointment_details(),
          keyword()
        ) :: organizer_details()
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
