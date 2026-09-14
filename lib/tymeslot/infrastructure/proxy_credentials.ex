defmodule Tymeslot.Infrastructure.ProxyCredentials do
  @moduledoc """
  The username and password an outbound proxy is authenticated with.

  A struct rather than the `{username, password}` tuple it replaces, for one
  reason: it carries the proxy password, and only a struct can refuse to print
  it. `@derive {Inspect, except: [:password]}` masks the field wherever the
  credentials are inspected — an exception message, a `dbg/1`, an OTP crash
  report that prints a task's arguments — which a tuple cannot do at all.

  A tuple is the worst shape a secret can have here, because every redaction
  this codebase has is keyed. `Logging.MetadataRedactor` scrubs sensitive
  *keys*; `Logging.Redactor` matches strings, but every pattern of its is
  anchored on a key name or a scheme word. A password sitting in the second
  position of a tuple has no key to match and is invisible to both. Widening
  the key list is not the fix either: `@sensitive_substrings` is matched with
  `String.contains?/2`, so a bare `auth` would also blank `needs_reauth`,
  `oauth_scope`, `dav_auth_type` and `unauthorized`, all of which are
  diagnostic and none of which are secret.

  This is the same conversion `Tymeslot.Integrations.Calendar.CalDAV.Client`
  and `Tymeslot.Integrations.Calendar.Exchange.ClientConfig` are for their
  respective credential-carrying configs.

  Build one through `new/1`; nothing else should construct one.
  `ProxyConfig.from_env/1` does so while `config/runtime.exs` runs, so the
  application environment never holds the password as a tuple, and
  `ProxyConfig.load/0` does so again for a tuple that arrived by another route.
  """

  @derive {Inspect, except: [:password]}
  defstruct [:username, :password]

  @type t :: %__MODULE__{
          username: String.t(),
          password: String.t()
        }

  @doc """
  Normalises proxy credentials into the struct.

  Accepts a `{username, password}` tuple of binaries, as parsed out of a proxy
  URL's userinfo, or `nil` when the URL carries none. A password-less proxy URL
  yields `{username, ""}`, which is why the empty password is allowed through
  rather than rejected.

  An existing struct passes back unchanged, so normalising twice is safe.
  """
  @spec new(t() | {String.t(), String.t()} | nil) :: t() | nil
  def new(nil), do: nil
  def new(%__MODULE__{} = credentials), do: credentials

  def new({username, password}) when is_binary(username) and is_binary(password) do
    %__MODULE__{username: username, password: password}
  end

  # Deliberately does not print the offending value. On this path it is
  # whatever the operator put in the `auth:` slot, and a value in that position
  # is exactly what this struct exists to keep out of messages.
  def new(_unsupported) do
    raise ArgumentError,
          "proxy credentials must be a {username, password} tuple of binaries, or nil " <>
            "(value withheld: it may carry the proxy password)"
  end
end
