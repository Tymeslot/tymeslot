defmodule Tymeslot.EmailSendingTestHelpers do
  @moduledoc "Shared SMTP dashboard setup actions and encrypted settings fixtures."

  use TymeslotWeb, :verified_routes

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  @endpoint TymeslotWeb.Endpoint

  @doc "Opens SMTP setup through its switch when the authenticated page starts collapsed."
  @spec open_smtp_settings(Plug.Conn.t()) :: {:ok, Phoenix.LiveViewTest.View.t(), String.t()}
  def open_smtp_settings(conn) do
    {:ok, view, html} = live(conn, ~p"/dashboard/settings")

    html =
      if has_element?(view, "#use-custom-smtp[aria-checked='false']"),
        do: view |> element("#use-custom-smtp") |> render_click(),
        else: html

    {:ok, view, html}
  end

  @doc "Inserts a tested, disabled identity with caller-supplied fixture credentials."
  @spec saved_smtp_settings(UserSchema.t(), map(), keyword()) :: UserSmtpSettingsSchema.t()
  def saved_smtp_settings(user, attrs, overrides \\ []) do
    settings = %{
      user_id: user.id,
      host: Map.fetch!(attrs, "host"),
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt(Map.fetch!(attrs, "username")),
      password_encrypted: Encryption.encrypt(Map.fetch!(attrs, "password")),
      from_address: Map.fetch!(attrs, "from_address"),
      from_name: Map.fetch!(attrs, "from_name"),
      enabled: false,
      revision: 1,
      tested_revision: 1,
      tested_at: DateTime.utc_now()
    }

    Repo.insert!(struct!(UserSmtpSettingsSchema, Map.merge(settings, Map.new(overrides))))
  end
end
