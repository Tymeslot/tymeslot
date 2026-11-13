defmodule TymeslotWeb.Themes.Shared.LiveHelpers.InvitationGate do
  @moduledoc """
  The entry gate of an invitation-only meeting type: it books only on a valid
  invitation for that type, which the booking page then holds as
  `:invitation` for the submit to claim.

  `StepEntry` asks it at two points: when the URL names the type (the slug),
  and when an entry names none (an in-page re-entry such as "schedule
  another", which keeps the held type and its invitation). In both, the token
  is the URL's `invite` parameter, else the one the page was let in on, so a
  link spent by a booking is refused again on re-entry. The owner's preview of
  a type books nothing and passes without an invitation. Every other type
  enters with no invitation.
  """

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Invitations
  alias Tymeslot.Invitations.InvitationSchema
  alias TymeslotWeb.Live.Scheduling.PreviewMode

  @doc """
  Checks an entry into `meeting_type`: `{:ok, invitation}` (nil for a type
  that is not invitation-only, and for the owner's preview of one), or
  `{:error, reason}` for `InvitationMessages.message/1`.
  """
  @spec check(Socket.t(), map(), map()) ::
          {:ok, InvitationSchema.t() | nil} | {:error, atom()}
  def check(socket, %{invitation_only: true, id: type_id}, params) do
    if PreviewMode.owner_preview?(socket) do
      {:ok, nil}
    else
      case Invitations.resolve(token(socket, params)) do
        {:ok, %{meeting_type_id: ^type_id} = invitation} -> {:ok, invitation}
        {:ok, _for_another_type} -> {:error, :required}
        {:error, :not_found} -> {:error, :required}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def check(_socket, _meeting_type, _params), do: {:ok, nil}

  @doc """
  The invitation-only type the page already holds, for an entry that names no
  type; nil when it holds none or a type anyone may book.
  """
  @spec held_type(Socket.t()) :: map() | nil
  def held_type(%Socket{assigns: %{meeting_type: %{invitation_only: true} = meeting_type}}),
    do: meeting_type

  def held_type(_socket), do: nil

  @doc """
  The form fields the host wrote on the invitation, which the booker may still
  change.
  """
  @spec prefill(map() | nil) :: %{optional(String.t()) => String.t()}
  def prefill(%{name: name, email: email}) do
    for {field, value} <- [{"name", name}, {"email", email}],
        is_binary(value) and value != "",
        into: %{},
        do: {field, value}
  end

  def prefill(nil), do: %{}

  # The URL's token, else the one this page was let in on. A crafted
  # `?invite[]=` is no token at all.
  defp token(_socket, %{"invite" => token}) when is_binary(token), do: token
  defp token(%{assigns: %{invitation: %{token: token}}}, _params), do: token
  defp token(_socket, _params), do: nil
end
