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

  use TymeslotWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Tymeslot.Auth
  alias TymeslotWeb.AuthLive.{SecurityHelper, StateHelper}
  alias TymeslotWeb.Helpers.ClientIP

  @typedoc "A LiveView `handle_event/3` return value."
  @type reply :: {:noreply, Phoenix.LiveView.Socket.t()}

  @doc """
  Validates the signup email as it is typed.

  Only email errors surface here; the password rules are the submit step's
  business, so a half-typed password is not flagged mid-keystroke.
  """
  @spec validate(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def validate(params, socket) do
    email = get_in(params, ["user", "email"]) || ""
    metadata = socket |> ClientIP.request_opts() |> Map.new()
    form_data = Map.merge(socket.assigns[:form_data] || %{}, %{email: email})

    errors =
      case Auth.validate_email(email, metadata) do
        {:ok, _sanitized} -> %{}
        {:error, message} -> %{email: message}
      end

    {:noreply, socket |> assign(:errors, errors) |> assign(:form_data, form_data)}
  end

  @doc """
  Submits the signup form once CSRF passes. The anti-abuse gate (honeypot,
  rate limit, reCAPTCHA) runs in the domain, as part of registering.
  """
  @spec submit(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def submit(%{"user" => user_params} = params, socket) do
    case SecurityHelper.validate_csrf_token(socket, params) do
      :ok ->
        register(socket, user_params)

      {:error, :invalid_csrf} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: SecurityHelper.csrf_message()})}
    end
  end

  defp register(socket, user_params) do
    request_opts = ClientIP.request_opts(socket)
    metadata = request_opts |> Map.new() |> Map.put(:source, "signup")

    case Auth.register_user(user_params, [metadata: metadata] ++ request_opts) do
      {:ok, user, message} ->
        {:noreply, answer_signup(socket, message, user_params, %{id: user.id, email: user.email})}

      {:existing_account, message} ->
        {:noreply, answer_signup(socket, message, user_params, nil)}

      {:honeypot, message} ->
        pretend_registered(socket, message, user_params)

      {:error, :input, errors} when is_map(errors) ->
        {:noreply, SecurityHelper.set_errors(socket, errors)}

      {:error, _reason, message} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: message})}
    end
  end

  # A new account and a taken address are answered identically; only the
  # binding differs, and it never leaves this process.
  defp answer_signup(socket, message, user_params, pending) do
    socket
    |> to_verify_email(:verify_email, message, user_params)
    |> bind_pending_verification(pending)
  end

  # The domain has already spent the verification allowance a real sign-up's
  # email would, and answered with a real sign-up's message.
  defp pretend_registered(socket, message, user_params) do
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
    |> StateHelper.transition_state(new_state, :signup)
    |> put_flash(:info, message)
    |> assign(:form_data, %{email: user_params["email"]})
    |> assign(:signed_up_here, true)
    |> push_patch(to: ~p"/auth/verify-email")
  end
end
