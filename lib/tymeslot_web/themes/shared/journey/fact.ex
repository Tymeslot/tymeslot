defmodule TymeslotWeb.Themes.Shared.Journey.Fact do
  @moduledoc """
  One thing a booking needs: the meeting type, a slot, the answers to the
  organiser's questions, the attendee.

  A fact works on the scheduling LiveView's own assigns (`:selected_duration`,
  `:meeting_type`, `:selected_date`, `:selected_time`, `:engine`, `:form`,
  ...); there is no separate session, so every helper keeps reading the
  assigns it reads today. A journey (`TymeslotWeb.Themes.Shared.Journey`)
  groups facts into moments; the engine routes each step event to the fact
  that owns it and asks the facts whether a moment may be left.

  The callbacks:

    * `key/0`: the fact's key in `Journey.facts/0` and in a moment's
      `collects:`;
    * `requires/1`: the facts that must be known before this one, for this
      booking (`Journey.build!/2` calls it with `%{}` for the static order);
    * `required?/1`: whether this booking needs the fact at all;
    * `known?/1`: whether the booking holds it;
    * `events/0`: the canonical event atoms (`StepEvents`' names) it owns;
    * `handle/3`: one of those events, with its data;
    * `enter/2` (optional): what showing a moment that collects the fact
      sets up, given the URL parameters, or `%{}` for a move inside the page;
    * `continue/1` (optional): whether the booker may leave a moment that
      collects it: `{:done, socket}`, `{:stay, socket}` (moved within the
      fact, as the questions wizard does) or `{:error, reason}`, a reason
      `BookingErrorMessage.message/1` renders;
    * `back/1` (optional): `{:stay, socket}` when "back" moves within the
      fact, else `{:leave, socket}`;
    * `revisitable?/1` (optional): whether "back" may return to a moment
      collecting it;
    * `default/2` and `default_strategies/0` (optional): settle the fact
      without asking, by a named strategy, and the strategies it takes;
    * `clear/1` (optional): forget the fact again;
    * `refresh/1` (optional): bring what the fact holds up to date with the
      facts it requires, after an event while a moment collecting it is
      shown and entered (the series' sessions follow another time picked
      above them on the same page);
    * `keeps_dependents?/2` (optional): whether an event that changed the
      fact, on a moment already answered, keeps what was built on it
      (given the assigns before and after), where the runtime would
      otherwise forget the facts depending on it.

  A fact `use`s this module, which defines every optional callback except
  `default/2` (`enter/2` returns the socket, `continue/1` is
  `{:done, socket}` once `known?/1` and `{:error, :incomplete}` before,
  `back/1` leaves, `revisitable?/1` is true, `default_strategies/0` is
  empty, `clear/1` and `refresh/1` return the socket unchanged,
  `keeps_dependents?/2` is false), each overridable. The engine calls them without checking, so a
  fact that only declares `@behaviour` is incomplete. `default/2` has no
  default: it is only called with a strategy listed in
  `default_strategies/0`, which `Journey.build!/2` checks.
  """

  alias Phoenix.LiveView.Socket

  @doc "The fact's key."
  @callback key() :: atom()

  @doc "The facts that must be known before this one, for this booking."
  @callback requires(assigns :: map()) :: [atom()]

  @doc "Whether this booking needs the fact at all."
  @callback required?(assigns :: map()) :: boolean()

  @doc "Whether the booking holds the fact."
  @callback known?(assigns :: map()) :: boolean()

  @doc "The canonical event atoms the fact owns."
  @callback events() :: [atom()]

  @doc "Handles one of the fact's events."
  @callback handle(Socket.t(), event :: atom(), data :: term()) :: {:noreply, Socket.t()}

  @doc "What showing a moment that collects the fact sets up."
  @callback enter(Socket.t(), params :: map()) :: Socket.t()

  @doc "Whether the booker may leave a moment collecting the fact."
  @callback continue(Socket.t()) :: {:done, Socket.t()} | {:stay, Socket.t()} | {:error, term()}

  @doc "Whether \"back\" moves within the fact or leaves its moment."
  @callback back(Socket.t()) :: {:leave, Socket.t()} | {:stay, Socket.t()}

  @doc "Whether \"back\" may return to a moment collecting the fact."
  @callback revisitable?(assigns :: map()) :: boolean()

  @doc "Settles the fact without asking, by `strategy`."
  @callback default(Socket.t(), strategy :: atom()) :: Socket.t()

  @doc "The strategies `default/2` takes."
  @callback default_strategies() :: [atom()]

  @doc """
  Forgets the fact: puts back the assigns a booking has before it was known,
  as far as they belong to this fact. `Journey.Runtime.clear/2` calls it for a
  fact and for every fact depending on it (a transcript's "Edit"). Optional;
  `use Fact` makes it return the socket unchanged.
  """
  @callback clear(Socket.t()) :: Socket.t()

  @doc """
  Brings the fact up to date with the facts it requires. The runtime calls
  it after every step event for each required fact a shown, entered moment
  collects (`Journey.Runtime.refresh_shown/1`), so it must leave a fact
  that is up to date unchanged. Optional; `use Fact` makes it return the
  socket unchanged.
  """
  @callback refresh(Socket.t()) :: Socket.t()

  @doc """
  Whether an event that changed the fact on an answered moment keeps the
  facts depending on it, given the assigns before and after the event.
  False forgets them (`Journey.Runtime`), as a changed fact normally does.
  Optional; `use Fact` makes it false.
  """
  @callback keeps_dependents?(before :: map(), after_event :: map()) :: boolean()

  @optional_callbacks enter: 2,
                      continue: 1,
                      back: 1,
                      revisitable?: 1,
                      default: 2,
                      default_strategies: 0,
                      clear: 1,
                      refresh: 1,
                      keeps_dependents?: 2

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def enter(socket, _params), do: socket

      @impl unquote(__MODULE__)
      def continue(socket) do
        if known?(socket.assigns), do: {:done, socket}, else: {:error, :incomplete}
      end

      @impl unquote(__MODULE__)
      def back(socket), do: {:leave, socket}

      @impl unquote(__MODULE__)
      def revisitable?(_assigns), do: true

      @impl unquote(__MODULE__)
      def default_strategies, do: []

      @impl unquote(__MODULE__)
      def clear(socket), do: socket

      @impl unquote(__MODULE__)
      def refresh(socket), do: socket

      @impl unquote(__MODULE__)
      def keeps_dependents?(_before, _after_event), do: false

      defoverridable enter: 2,
                     continue: 1,
                     back: 1,
                     revisitable?: 1,
                     default_strategies: 0,
                     clear: 1,
                     refresh: 1,
                     keeps_dependents?: 2
    end
  end
end
