defmodule Tymeslot.Emails.Shared.TemplateHelper do
  @moduledoc """
  Helper functions for standardized template compilation and organizer details generation.
  """

  alias Tymeslot.Emails.Shared.{AvatarHelper, MjmlEmail}

  @doc """
  Standardized function to create organizer details for email templates.
  """
  @spec build_organizer_details(map()) :: map()
  def build_organizer_details(appointment_details) do
    %{
      name: appointment_details.organizer_name,
      email: appointment_details.organizer_email,
      avatar_url: AvatarHelper.generate_avatar_url(appointment_details),
      title: appointment_details.organizer_title || "Tymeslot"
    }
  end

  @doc """
  Standardized function to create system organizer details for system emails.
  """
  @spec build_system_organizer_details(String.t()) :: map()
  def build_system_organizer_details(title \\ "Tymeslot") do
    %{
      name: "Tymeslot",
      email: MjmlEmail.fetch_from_email(),
      title: title
    }
  end

  @doc """
  Compiles MJML content with organizer details into HTML.
  """
  @spec compile_template(String.t(), map()) :: String.t()
  def compile_template(mjml_content, organizer_details) do
    mjml_content
    |> MjmlEmail.base_mjml_template(organizer_details)
    |> MjmlEmail.compile_mjml()
  end

  @doc """
  Compiles MJML content for system emails into HTML.
  """
  @spec compile_system_template(String.t(), String.t()) :: String.t()
  def compile_system_template(mjml_content, title \\ "Tymeslot") do
    organizer_details = build_system_organizer_details(title)
    compile_template(mjml_content, organizer_details)
  end

  @doc """
  Formats error reasons for display in templates.
  """
  @spec format_error_reason(any()) :: String.t()
  def format_error_reason(reason) when is_binary(reason), do: reason
  def format_error_reason(reason), do: inspect(reason)
end
