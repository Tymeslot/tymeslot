defmodule TymeslotWeb.AuthLive.SignupEvents do
  @moduledoc """
  The signup flow's event handlers, lifted out of `TymeslotWeb.AuthLive`.

  ## Why a taken address looks like a success

  Signing up with an address that already has an account answers with the same
  message, state and screen as a new account, so the form cannot be used to
  learn who is registered. The owner is emailed instead. The only difference
  is server-side: no account is bound for the verify-email screen's resend.

  ## Why a honeypot submission looks like a success

  A submission caught by the honeypot is answered with the same message, the
  same state transition and the same redirect as a real one. That is the point:
  telling a bot it was detected teaches whoever wrote it which field to leave
  alone next time. The only difference is that no account exists, so the
  verify-email screen is flagged (`honeypot_signup`) and the resend handler
  answers it without touching the database.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Tymeslot.Auth.{AuthActions, SignupSecurity}
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.AuthLive.SecurityHelper

  @typedoc "A LiveView `handle_event/3` return value."
  @type reply :: {:noreply, Phoenix.LiveView.Socket.t()}

  @doc """
  Validates the signup email as it is typed.

  Only email errors surface here; the password rules are the submit step's
  business, so a half-typed password is not flagged mid-keystroke.
  """
  @spec validate(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def validate(params, socket) do
    user_params = params["user"] || %{}
    metadata = SecurityHelper.extract_client_metadata(socket)
    form_data = Map.merge(socket.assigns[:form_data] || %{}, %{email: user_params["email"] || ""})

    errors =
      case InputProcessor.validate_form(user_params, [{"email", :email}], metadata: metadata) do
        {:ok, _sanitized} -> %{}
        {:error, errors} -> Map.take(errors, [:email])
      end

    {:noreply, socket |> assign(:errors, errors) |> assign(:form_data, form_data)}
  end

  @doc """
  Submits the signup form, once CSRF and the anti-abuse gate both pass.
  """
  @spec submit(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def submit(%{"user" => user_params} = params, socket) do
    with :ok <- SecurityHelper.validate_csrf_token(socket, params),
         metadata = SecurityHelper.extract_client_metadata(socket),
         :ok <- SignupSecurity.gate(user_params, metadata) do
      register(socket, user_params)
    else
      :honeypot ->
        pretend_registered(socket, user_params)

      {:error, :invalid_csrf} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: csrf_message()})}

      {:error, _kind, message} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: message})}
    end
  end

  defp register(socket, user_params) do
    case AuthActions.register_user(user_params, socket) do
      {:ok, new_state, message, pending} ->
        socket =
          socket
          |> to_verify_email(new_state, message, user_params)
          |> bind_pending_verification(pending)

        {:noreply, socket}

      {:error, :field_errors, errors} ->
        {:noreply, SecurityHelper.set_errors(socket, errors)}

      {:error, error_message} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: error_message})}
    end
  end

  defp pretend_registered(socket, user_params) do
    message =
      dgettext(
        "auth",
        "Account created successfully. Please check your email for verification instructions."
      )

    socket =
      socket
      |> to_verify_email(:verify_email, message, user_params)
      |> bind_pending_verification(nil)
      |> assign(:honeypot_signup, true)

    {:noreply, socket}
  end

  # The account the verify-email screen may resend for, held in this process
  # only: a new sign-up's own account, or none when the address was already
  # taken (so a resend there goes nowhere, and says so in the same words).
  # Replacing any earlier binding matters too: a sign-up must never leave the
  # resend pointing at an account from before it.
  defp bind_pending_verification(socket, nil), do: assign(socket, :unverified_user, nil)

  defp bind_pending_verification(socket, %{id: id, email: email}) do
    assign(socket, :unverified_user, %{
      id: id,
      email: email,
      timestamp: DateTime.to_unix(DateTime.utc_now())
    })
  end

  # `signed_up_here` marks that this process answered a sign-up, whatever its
  # outcome, so the resend knows it owes the visitor the sign-up's answer and
  # not the reload one (see `TymeslotWeb.AuthLive.VerificationEvents`).
  defp to_verify_email(socket, new_state, message, user_params) do
    socket
    |> AuthActions.transition_state(new_state, :signup)
    |> put_flash(:info, message)
    |> assign(:form_data, %{email: user_params["email"]})
    |> assign(:signed_up_here, true)
    |> push_patch(to: ~p"/auth/verify-email")
  end

  defp csrf_message,
    do: dgettext("auth", "Security validation failed. Please refresh the page.")
end
