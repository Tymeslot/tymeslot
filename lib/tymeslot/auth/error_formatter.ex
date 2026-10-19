defmodule Tymeslot.Auth.ErrorFormatter do
  @moduledoc """
  Unified error formatting for the authentication system.

  This module provides consistent error messages across all authentication
  operations, preventing information leakage and improving user experience.

  Every message it returns is user-facing, so it is translated in the `auth`
  domain. Changeset messages are translated in the `errors` domain, matching
  what `CoreComponents.Forms.translate_error/1` does for inline form errors.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Utils.ChangesetErrors

  @doc """
  The message shown for a failed sign-in, sign-up or password-flow policy
  check, by reason.

  Every reason that means "these credentials did not get you in" (an unknown
  address, a wrong password) shares one message, so the reply never tells a
  visitor which it was. A reason with no clause of its own is a bug below,
  answered with a generic message rather than a crash.
  """
  @spec format_auth_error(atom()) :: String.t()
  def format_auth_error(reason) when reason in [:not_found, :invalid_password],
    do: generic_auth_error()

  def format_auth_error(:oauth_user) do
    dgettext(
      "auth",
      "This email is associated with a social login. Please use your original sign-in method."
    )
  end

  def format_auth_error(:rate_limited), do: too_many_attempts()

  def format_auth_error(:registration_disabled),
    do: dgettext("auth", "Registration is currently disabled.")

  def format_auth_error(:password_auth_disabled),
    do: dgettext("auth", "Password authentication is currently disabled.")

  def format_auth_error(_reason), do: dgettext("auth", "An error occurred. Please try again.")

  @doc """
  The message shown when a password reset (the request, or setting the new
  password) fails, by reason.

  A rejected new password is not handled here: its message names the rule
  it broke and is shown as the domain wrote it. Every other reason describes
  the token or the requester. A reason with no clause is a bug below; it is
  logged and answered with the generic server error, never a crash, since
  the reset pages are public.
  """
  @spec format_password_reset_error(atom()) :: String.t()
  def format_password_reset_error(:rate_limited), do: too_many_attempts()

  def format_password_reset_error(:invalid_token),
    do: dgettext("auth", "Invalid or expired token")

  def format_password_reset_error(:token_expired),
    do: dgettext("auth", "This link has expired. Please request a new one")

  def format_password_reset_error(:invalid_password), do: dgettext("auth", "Invalid password")

  def format_password_reset_error(other) do
    Logger.error("Unmapped auth error reason",
      reason: LogFormat.reason(other),
      event: :auth_error_unmapped
    )

    server_error()
  end

  defp too_many_attempts, do: dgettext("auth", "Too many attempts. Please try again later.")

  defp server_error, do: dgettext("auth", "A server error occurred. Please try again")

  @doc """
  Joins a map of field errors, each already a message in the reader's
  language, into one line. Field names are not added: a message names its
  subject itself, in its own language.
  """
  @spec format_validation_errors(%{atom() => String.t() | [String.t()]}) :: String.t()
  def format_validation_errors(errors) when is_map(errors) do
    errors
    |> Enum.flat_map(fn {_field, messages} -> List.wrap(messages) end)
    |> Enum.join(". ")
  end

  @doc """
  A changeset's first error as one line, in the current locale, prefixed
  "Label: " when `labels` names its field (for a flash, away from the
  field). `nil` when the changeset has no errors. See
  `Tymeslot.Utils.ChangesetErrors.first/3`.
  """
  @spec first_error(Changeset.t(), %{atom() => String.t()}) :: String.t() | nil
  def first_error(%Changeset{} = changeset, labels \\ %{}),
    do: ChangesetErrors.first(changeset, &ChangesetErrors.translate/1, labels)

  # Returns a generic authentication error message to prevent user enumeration.
  @spec generic_auth_error() :: String.t()
  defp generic_auth_error do
    dgettext(
      "auth",
      "Invalid email or password. If you signed up recently, check your inbox for the verification link."
    )
  end

  @doc """
  Formats a registration refused by the user changeset as a
  user-friendly message.

  A taken address never reaches this: registration answers it as a success,
  so nothing here may say an address is registered.
  """
  @spec format_user_friendly_error(String.t(), Changeset.t()) :: String.t()
  def format_user_friendly_error("registration" = operation, %Changeset{} = changeset) do
    if unique_refusal?(changeset) do
      dgettext("auth", "This information is already in use. Please try with different details.")
    else
      operation_failed(operation, first_error(changeset, registration_labels()))
    end
  end

  # Read from the refusal's own metadata, never from its wording, which is in
  # the reader's language.
  defp unique_refusal?(%Changeset{errors: errors}),
    do: Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end)

  defp registration_labels do
    %{email: dgettext("auth", "Email address"), password: dgettext("auth", "Password")}
  end

  defp operation_failed(operation, reason) do
    dgettext("auth", "%{operation} failed: %{reason}",
      operation: operation_name(operation),
      reason: reason
    )
  end

  defp operation_name("registration"), do: dgettext("auth", "Registration")

  @doc """
  The message for an operation refused by a rate limit, naming the operation.
  """
  @spec format_rate_limit_error(String.t()) :: String.t()
  def format_rate_limit_error(operation) do
    dgettext("auth", "Too many %{operation} attempts. Please try again later.",
      operation: rate_limit_operation(operation)
    )
  end

  # The operation is interpolated into a translated sentence, so the labels
  # the auth flows pass are translated too. Anything else falls through as-is.
  defp rate_limit_operation("authentication"), do: dgettext("auth", "authentication")
  defp rate_limit_operation(operation), do: operation
end
