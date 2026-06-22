defmodule Tymeslot.Analytics.UtmExtractor do
  @moduledoc """
  Extracts UTM and known attribution parameters from query params.

  Standard UTM fields land in their own typed keys (so they get dedicated
  columns and indexes). A small **allowlist** of well-known ad-network and
  click-identifier params is preserved in a `tracking_params` map.

  The allowlist is deliberate: `tracking_params` is persisted both to
  `analytics_events` and — on booking — onto the invitee's `meetings` row
  next to their name and email, indefinitely. Capturing *arbitrary* query
  params there would silently persist visitor PII (e.g. `?email=`, `?phone=`,
  session tokens) onto a personal-data record. Only recognised attribution
  identifiers are kept; everything else is dropped.
  """

  @utm_keys ~w(utm_source utm_medium utm_campaign utm_content utm_term)

  # Allowlist of non-UTM attribution params preserved in `tracking_params`.
  # Limited to recognised ad-network / click identifiers and the generic
  # `ref` referral tag — none of which carry personal data. Add new entries
  # here as new ad networks appear; never widen this to "any param".
  @tracking_keys ~w(
    gclid gbraid wbraid gclsrc dclid
    fbclid
    msclkid
    ttclid
    twclid
    li_fat_id
    igshid
    yclid
    rdt_cid
    epik
    mc_cid mc_eid
    ref
  )

  @max_value_length 255
  @max_tracking_keys 16

  @type extracted :: %{
          utm_source: String.t() | nil,
          utm_medium: String.t() | nil,
          utm_campaign: String.t() | nil,
          utm_content: String.t() | nil,
          utm_term: String.t() | nil,
          tracking_params: %{String.t() => String.t()}
        }

  @spec extract(map() | nil) :: extracted()
  def extract(nil), do: empty()
  def extract(params) when params == %{}, do: empty()

  def extract(params) when is_map(params) do
    base = empty()

    Enum.reduce(params, base, fn
      {k, v}, acc when is_binary(k) and is_binary(v) ->
        place(acc, k, truncate(v))

      _other, acc ->
        acc
    end)
  end

  @spec referrer_host(String.t() | nil) :: String.t() | nil
  def referrer_host(nil), do: nil
  def referrer_host(""), do: nil

  def referrer_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host |> String.downcase() |> String.slice(0, 255)

      _other ->
        nil
    end
  end

  defp empty do
    %{
      utm_source: nil,
      utm_medium: nil,
      utm_campaign: nil,
      utm_content: nil,
      utm_term: nil,
      tracking_params: %{}
    }
  end

  defp place(acc, key, value) when key in @utm_keys do
    Map.put(acc, String.to_existing_atom(key), value)
  end

  defp place(acc, key, value) when key in @tracking_keys do
    Map.update!(acc, :tracking_params, fn params ->
      if map_size(params) >= @max_tracking_keys do
        params
      else
        Map.put(params, key, value)
      end
    end)
  end

  # Anything outside the UTM set and the attribution allowlist is dropped —
  # routing params (username, slug, …) and any unrecognised param that could
  # carry visitor PII never reach the persisted tracking map.
  defp place(acc, _key, _value), do: acc

  defp truncate(value) when byte_size(value) <= @max_value_length, do: value
  defp truncate(value), do: String.slice(value, 0, @max_value_length)
end
