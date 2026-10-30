defmodule Tymeslot.Integrations.Calendar.CalDAV.Client do
  @moduledoc """
  The connected CalDAV client every CalDAV-family provider hands to
  `Base.*` and `Http.*`.

  A struct rather than a plain map for one reason: it carries the
  integration's decrypted password, and only a struct can refuse to print it.
  `@derive {Inspect, except: [:password]}` masks the field wherever the client
  is inspected — an exception message, a `dbg/1`, an OTP crash report that
  prints a task's arguments — which is what a plain map cannot do however
  carefully the schema that produced the value marked it `redact: true`.

  Build one through `build_client/2`, or `build_provider_client/4` and
  `client_for_integration/1` on top of it (`Providers.CaldavCommon`
  delegates all three); nothing else should construct it directly.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Family
  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider

  @derive {Inspect, except: [:password]}
  defstruct [
    :base_url,
    :username,
    :password,
    :provider,
    calendar_paths: [],
    # Every collection on the integration a write is allowed to target, which
    # is not the same as the one this client defaults to. A booking client
    # addresses one collection, but the calendar grid lets the organiser pick
    # another, and `CaldavCommon.create_event/2` needs a list to check that
    # choice against: a `calendar_id` off the event payload is caller-supplied
    # and must never be able to send a write to an arbitrary path.
    writable_calendar_paths: [],
    # Collections shared with the account as busy times only, read through
    # the free-busy-query REPORT rather than calendar-query (`CalDAV.FreeBusy`).
    free_busy_paths: [],
    # Set only for a discovery a person asked for (validating a connection,
    # reconnecting it): it has to reach a server whose host breaker its
    # earlier failures opened, since that is how the breaker gets closed.
    # Those paths are rate-limited per user already.
    skip_breaker: false
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          provider: atom(),
          calendar_paths: [String.t()],
          writable_calendar_paths: [String.t()],
          free_busy_paths: [String.t()],
          skip_breaker: boolean()
        }

  @doc """
  `url` trimmed of surrounding whitespace and any trailing slash, the form
  every client's `base_url` is stored in; `nil` becomes `""`.
  """
  @spec normalize_url(String.t() | nil) :: String.t()
  def normalize_url(nil), do: ""

  def normalize_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  @doc """
  Builds a provider's client from the config its `new/1` is given, with the
  base URL and calendar paths already put into that provider's own form.

  The credentials and `:writable_calendar_paths` are carried over as given.
  A provider that rebuilt the config by hand used to drop the writable paths,
  and the client then wrote every event to its booking calendar, whichever
  calendar the organiser had picked.
  """
  @spec build_provider_client(map(), atom(), String.t() | nil, [String.t()]) :: t()
  def build_provider_client(config, provider, base_url, calendar_paths) do
    build_client(
      %{
        base_url: base_url,
        username: config[:username],
        password: config[:password],
        calendar_paths: calendar_paths,
        writable_calendar_paths: config[:writable_calendar_paths],
        free_busy_paths: config[:free_busy_paths],
        skip_breaker: config[:skip_breaker] || false
      },
      provider: provider
    )
  end

  @doc """
  Builds the client struct downstream Base.* functions run on.

  Accepts atom- or string-keyed config with `:base_url`, `:username`,
  `:password`, `:calendar_paths`, and `:writable_calendar_paths`; takes the provider from
  `opts`. This is the only place a `Client` is constructed, which is what
  makes the password's inspect-time redaction hold for every CalDAV-family
  provider.
  """
  @spec build_client(%{atom() => term()} | %{String.t() => term()}, keyword()) :: t()
  def build_client(config, opts) when is_map(config) do
    provider = Keyword.fetch!(opts, :provider)

    %__MODULE__{
      base_url: normalize_url(Map.get(config, :base_url) || Map.get(config, "base_url")),
      username: Map.get(config, :username) || Map.get(config, "username"),
      password: Map.get(config, :password) || Map.get(config, "password"),
      calendar_paths: Map.get(config, :calendar_paths) || [],
      writable_calendar_paths:
        Map.get(config, :writable_calendar_paths) ||
          Map.get(config, "writable_calendar_paths") || [],
      free_busy_paths: Map.get(config, :free_busy_paths) || [],
      skip_breaker: Map.get(config, :skip_breaker, false),
      provider: provider
    }
  end

  # The provider is a string on the integration row and an atom on the client,
  # so the mapping belongs here, with the client it feeds. A generic
  # `"caldav"` row is not in it: its client takes the server type detected
  # from the URL, as every other generic CalDAV client does, so that its
  # calls trip the host breaker a reset closes
  # (`CalendarCircuitBreaker.breaker_key/2`). Read at runtime rather than
  # into a module attribute, so the struct module, which much of the app
  # compiles against, takes no compile-time dependency on `Family`.

  @doc """
  Builds a client from a stored calendar integration row.
  """
  @spec client_for_integration(map()) :: t()
  def client_for_integration(integration) do
    build_client(
      %{
        base_url: integration.base_url,
        username: integration.username,
        password: integration.password,
        calendar_paths: integration.calendar_paths
      },
      provider: client_provider(integration)
    )
  end

  defp client_provider(%{provider: provider, base_url: base_url}) do
    case Map.fetch(Family.client_providers(), provider) do
      {:ok, provider_atom} -> provider_atom
      :error -> CalDAVProvider.client_provider(base_url)
    end
  end
end
