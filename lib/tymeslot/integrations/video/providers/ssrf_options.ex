defmodule Tymeslot.Integrations.Video.Providers.SsrfOptions do
  @moduledoc """
  The request options that put an outbound video provider call behind the
  SSRF guard.

  A self-hosted video provider talks to a host its user typed in, so every
  request has to carry `ssrf_protect: true` and read the video opt-out through
  `SsrfGuard.allow_private_for_video?/0` (`ALLOW_PRIVATE_IPS_FOR_VIDEO`, which
  also honours the older calendar switch for existing deployments) rather than
  the calendar check alone. Defined once, outside any single provider's
  namespace, so a new provider cannot pick up the first option while silently
  reading the wrong switch.
  """

  alias Tymeslot.Security.SsrfGuard

  @doc """
  The options to add to every request a video provider sends to a
  user-supplied host.

  Built per call rather than as a module attribute: the opt-out is read from
  application config at runtime, and an attribute would freeze it at compile
  time.
  """
  @spec request_options() :: keyword()
  def request_options do
    [ssrf_protect: true, ssrf_allow_private: SsrfGuard.allow_private_for_video?()]
  end
end
