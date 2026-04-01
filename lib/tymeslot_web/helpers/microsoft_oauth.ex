defmodule TymeslotWeb.Helpers.MicrosoftOAuth do
  @moduledoc """
  Shared helpers for Microsoft OAuth error handling across calendar and video controllers.
  """

  # Microsoft returns an error_description containing an AADSTS code when a tenant's
  # user consent policy requires an IT admin to approve the app before individuals
  # can authorise it. Detecting these codes lets us show actionable guidance instead
  # of a generic "access denied" message.
  @microsoft_admin_consent_codes ~w[AADSTS65001 AADSTS90094 AADSTS90093 AADSTS90095]

  @doc """
  Returns `true` when the error description contains an AADSTS code indicating
  that the Microsoft tenant requires admin consent before an individual user
  can authorise the application.
  """
  @spec microsoft_admin_consent_error?(String.t()) :: boolean()
  def microsoft_admin_consent_error?(description) do
    Enum.any?(@microsoft_admin_consent_codes, &String.contains?(description, &1))
  end
end
