defmodule TymeslotWeb.AdminLive.Formatters do
  @moduledoc """
  Pure formatting helpers shared across the admin tabs.

  Centralised here so labels and value rendering stay consistent between the
  overview, settings, and users tabs.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "Human-readable label for an `AppSettings` key."
  @spec humanise(atom()) :: String.t()
  def humanise(:registration_enabled), do: gettext("Registration enabled")
  def humanise(:password_auth_enabled), do: gettext("Password authentication")

  def humanise(key),
    do: key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  @doc """
  Short, human-readable description of what a setting controls. Shown
  beneath the setting name on the admin settings page.

  The recommended value is rendered separately by `recommended/1` so the
  UI can give it its own visual treatment.
  """
  @spec describe(atom()) :: String.t()
  def describe(:registration_enabled) do
    gettext(
      "Allow new users to sign up via the public registration page. Disable for a private install where admins create accounts manually."
    )
  end

  def describe(:password_auth_enabled) do
    gettext(
      "Allow log-in with email and password. When disabled, users can only authenticate through configured OAuth providers."
    )
  end

  def describe(_other), do: ""

  @doc """
  The recommended value for a setting, or `nil` if there is no recommendation.
  Rendered as a separate chip beneath the description.
  """
  @spec recommended(atom()) :: boolean() | nil
  def recommended(:registration_enabled), do: true
  def recommended(:password_auth_enabled), do: true
  def recommended(_other), do: nil

  @doc "Human-readable label for a recommended boolean value."
  @spec recommended_label(boolean()) :: String.t()
  def recommended_label(true), do: gettext("Enabled")
  def recommended_label(false), do: gettext("Disabled")
end
