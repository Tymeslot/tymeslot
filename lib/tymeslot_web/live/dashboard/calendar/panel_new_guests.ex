defmodule TymeslotWeb.Dashboard.Calendar.PanelNewGuests do
  @moduledoc """
  The guests of the side panel's New event draft (see `PanelNew`). Nobody
  is emailed until the draft is created; until then a guest is only a chip.

  Every address is checked with the domain's own rules
  (`CreateParams.guests/2`: a valid address, not the organiser's, at most
  `CreateParams.max_guests/0`), so the chips never promise an invitation a
  create would drop. An address typed into the guest field but not added
  when Create is pressed is added first (`take_pending/2`), as the old
  Quick Add did: a valid one joins the draft, and one that is not, or the
  organiser's own, stops the create with its reason.

  While "Send as a Tymeslot meeting" is ticked the meeting's own limit
  holds at Add (`max/1`): the guest it is with and `Guests.max_guests/0`
  others, or that many guests without a main participant. At the limit
  the guest field gives way (`full?/1`), as in the old Quick Add.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.MeetingParams
  alias Tymeslot.Meetings.Guests
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.PanelNew

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  The guests the hook sent with the draft, checked as a create checks them,
  and the panel's starting status: ones the domain refuses leave the form
  with none and the reason in the header.
  """
  @spec typed(socket(), term()) :: {[String.t()], PanelNew.status()}
  def typed(socket, list) when is_list(list) do
    case CreateParams.guests(socket.assigns.current_user.id, Enum.filter(list, &is_binary/1)) do
      {:ok, guests} -> {guests, :idle}
      {:error, field, reason} -> {[], {:failed, Creation.refusal_message(field, reason)}}
    end
  end

  def typed(_socket, _other), do: {[], :idle}

  @doc """
  The address typed into the guest field and not added yet, among a form
  change's `params`, as `"guest_pending"`: a valid address other than the
  organiser's (`user`) counts as a guest for what the form offers (the
  meeting box, "Create and invite"), since Create adds it.
  """
  @spec pending(map(), map()) :: map()
  def pending(%{"guest_email" => typed}, user) when is_binary(typed) do
    email = typed |> String.replace("\x00", "") |> String.trim() |> String.downcase()
    own = String.downcase(user.email || "")

    if Guests.valid_email?(email) and email != own,
      do: %{"guest_pending" => email},
      else: %{"guest_pending" => ""}
  end

  def pending(_params, _user), do: %{}

  @doc "Adds the guest `raw` to the draft, or says why it is not added."
  @spec add(socket(), String.t()) :: socket()
  def add(socket, raw) do
    case put(socket, raw) do
      {:ok, socket} -> socket
      {_refused_or_already, socket, message} -> warn(socket, message)
    end
  end

  @doc """
  Adds the address left in the guest field, if any, before a create:
  `{:ok, socket}` to go on (nothing typed, the address added, or one the
  draft already has), `{:error, socket}` when it is refused, which says why.
  """
  @spec take_pending(socket(), term()) :: {:ok, socket()} | {:error, socket()}
  def take_pending(socket, raw) when is_binary(raw) do
    if String.trim(raw) == "" do
      {:ok, socket}
    else
      case put(socket, raw) do
        {:ok, socket} -> {:ok, socket}
        {:already, socket, _message} -> {:ok, socket}
        {:refused, socket, message} -> {:error, warn(socket, message)}
      end
    end
  end

  def take_pending(socket, _raw), do: {:ok, socket}

  @doc """
  How many guests the draft would invite: those added, and one typed but
  not added yet (`pending/2`).
  """
  @spec count(map()) :: non_neg_integer()
  def count(form) do
    added = length(form["guests"] || [])
    if (form["guest_pending"] || "") != "", do: added + 1, else: added
  end

  @doc "Drops the guest `email` from the draft."
  @spec drop(socket(), String.t()) :: socket()
  def drop(%{assigns: %{panel: %{form: form}}} = socket, email),
    do: PanelNew.put_form(socket, %{form | "guests" => List.delete(form["guests"], email)})

  defp put(%{assigns: %{panel: %{form: form}}} = socket, raw) do
    user_id = socket.assigns.current_user.id
    guests = form["guests"]

    with {:ok, [email]} <- CreateParams.guests(user_id, [raw]),
         :ok <- not_yet_a_guest(guests, email),
         :ok <- room_for_one_more(form),
         {:ok, _kept} <- CreateParams.guests(user_id, guests ++ [email]) do
      form = Map.merge(form, %{"guests" => guests ++ [email], "guest_pending" => ""})
      socket = PanelNew.put_form(socket, form)
      {:ok, assign(socket, :guest_form_key, socket.assigns.guest_form_key + 1)}
    else
      {:ok, []} -> {:refused, socket, Creation.guest_message(:organiser)}
      {:error, :guests, :too_many} -> {:refused, socket, too_many()}
      {:error, :guests, _invalid} -> {:refused, socket, Creation.guest_message(:invalid)}
      {:error, :already_a_guest, email} -> already(socket, email)
      {:error, :meeting_full} -> {:refused, socket, meeting_full()}
    end
  end

  @doc """
  The most guests the draft can have: a meeting's limit while the box is
  ticked (with a main participant, the guest it is with besides the
  others), an event's otherwise.
  """
  @spec max(map()) :: pos_integer()
  def max(%{"meeting" => true, "main_participant" => false}), do: Guests.max_guests()
  def max(%{"meeting" => true}), do: MeetingParams.max_guests()
  def max(_form), do: CreateParams.max_guests()

  @doc "Whether a meeting draft holds as many guests as it can, so no more can be added."
  @spec full?(map()) :: boolean()
  def full?(%{"meeting" => true} = form), do: length(form["guests"] || []) >= max(form)
  def full?(_form), do: false

  defp room_for_one_more(form),
    do: if(full?(form), do: {:error, :meeting_full}, else: :ok)

  defp meeting_full,
    do: dgettext("dashboard_calendar_editing", "No more guests can be added to this meeting.")

  # Add says so; a create goes on, as the address is already invited.
  defp already(socket, email),
    do: {:already, socket, Creation.guest_message({:duplicate, email})}

  defp too_many, do: Creation.refusal_message(:guests, :too_many)

  defp not_yet_a_guest(guests, email),
    do: if(email in guests, do: {:error, :already_a_guest, email}, else: :ok)

  defp warn(socket, message) do
    send(self(), {:flash, {:warning, message}})
    socket
  end
end
