defmodule Tymeslot.Integrations.Calendar.CalDAV.DigestAuth do
  @moduledoc """
  HTTP Digest authentication (RFC 7616, and the RFC 2069 form that predates it)
  for the CalDAV transport.

  CalDAV servers do not agree on an authentication scheme. Most accept Basic
  over TLS, which is what `CalDAV.Http` sends first, but Baikal ships
  `dav_auth_type: Digest` as its *default* and SabreDAV rejects a Basic header
  outright in that mode — it never falls back, so a Basic-only client cannot
  reach a stock Baikal install at all. This module turns the server's 401
  challenge into the `Authorization: Digest` header that answers it.

  ## What is supported

  The algorithms real servers offer: `MD5` (and the RFC 2617 default of no
  `algorithm` parameter at all), `SHA-256`, `SHA-512-256`, and the `-sess`
  variant of each. `qop=auth` and the legacy no-`qop` form both work.

  `qop=auth-int` is not supported. It hashes the request body into the
  credentials, which means the body must be materialised and digested before
  the header can be built, and no CalDAV server in circulation offers it —
  SabreDAV, Radicale, Nextcloud and Zimbra all advertise `auth` alone. A
  challenge offering only `auth-int` is reported as unsupported rather than
  answered wrongly.

  ## No nonce caching

  A challenge is answered once and discarded, so a digest server costs two
  round trips per request rather than one. Reusing a nonce across requests is
  legal (that is what the nonce count is for) but needs per-origin shared
  state, a monotonic counter, and `stale=true` re-challenge handling — three
  moving parts, in exchange for latency on the minority of servers that speak
  digest at all. Revisit if digest servers become the common case.
  """

  alias Req.Response

  # RFC 7616, Section 3.3 — the hash each algorithm name selects. The `-sess`
  # variants hash identically and differ only in how HA1 is derived, so they
  # map to the same function here.
  @hashes %{
    "md5" => :md5,
    "md5-sess" => :md5,
    "sha-256" => :sha256,
    "sha-256-sess" => :sha256,
    "sha-512-256" => :sha512_256,
    "sha-512-256-sess" => :sha512_256
  }

  # RFC 2617 predates the `algorithm` parameter; a challenge that omits it
  # means MD5.
  @default_algorithm "md5"

  @typedoc """
  Why a 401 produced no `Authorization` header.

  `:none` means the response carried no Digest challenge at all — an ordinary
  rejected-credentials 401 from a Basic-auth server. `{:unsupported, detail}`
  means the server did challenge for Digest but named parameters this module
  cannot satisfy; `detail` is a sentence naming them, for the operator log.
  """
  @type failure :: :none | {:unsupported, String.t()}

  @doc """
  Builds the `Authorization` header answering a 401's Digest challenge.

  `method` is the uppercase HTTP method as it goes on the wire (`"PROPFIND"`,
  `"PUT"`, …) and `url` the full request URL; both are hashed into the
  credentials, so they must match the request the header will be sent on.

  `:client_nonce` overrides the randomly generated cnonce. It exists so the
  published RFC 7616 test vectors can be reproduced exactly — every other
  input to the digest is fixed by the challenge, so without it the computed
  response cannot be compared against a known-correct value, only against a
  second copy of the same arithmetic. Production callers must not pass it: a
  reused client nonce is what the value is there to prevent.
  """
  @spec build_authorization(
          Response.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, {String.t(), String.t()}} | failure()
  def build_authorization(%Response{} = response, method, url, username, password, opts \\ [])
      when is_binary(username) and is_binary(password) do
    with {:ok, challenge} <- challenge(response),
         {:ok, hash} <- hash_algorithm(challenge),
         {:ok, qop} <- quality_of_protection(challenge) do
      cnonce = Keyword.get_lazy(opts, :client_nonce, &client_nonce/0)

      {:ok,
       {"Authorization",
        header_value(challenge, hash, qop, method, url, username, password, cnonce)}}
    end
  end

  # Challenge parsing

  @spec challenge(Response.t()) :: {:ok, map()} | :none
  defp challenge(response) do
    response
    |> Response.get_header("www-authenticate")
    |> Enum.find_value(:none, fn value ->
      params = digest_params(value)

      # A challenge without a nonce cannot be answered, and every server sends
      # one; treating it as absent keeps a malformed header from being read as
      # a digest offer.
      if Map.has_key?(params, "nonce"), do: {:ok, params}
    end)
  end

  # A single `WWW-Authenticate` header may carry several challenges
  # (`Digest realm="x", nonce="y", Basic realm="x"`), so the parameters are
  # walked with the scheme they belong to and only the Digest ones kept.
  # First value wins, which is what makes a trailing `Basic realm=` unable to
  # overwrite the realm the digest credentials are computed against.
  defp digest_params(value) do
    value
    |> comma_separated_parts()
    |> Enum.reduce({nil, %{}}, &collect_param/2)
    |> elem(1)
  end

  # Commas separate parameters, except inside a quoted string: a realm is
  # free to contain one. Escaped quotes inside a quoted string are not
  # handled — no server in practice emits them, and mis-splitting one would
  # yield a challenge without a nonce, which is already treated as absent.
  defp comma_separated_parts(value) do
    {parts, last, _in_quotes} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", false}, fn
        "\"", {parts, current, in_quotes} -> {parts, current <> "\"", not in_quotes}
        ",", {parts, current, false} -> {[current | parts], "", false}
        char, {parts, current, in_quotes} -> {parts, current <> char, in_quotes}
      end)

    [last | parts]
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp collect_param(part, {scheme, params}) do
    {scheme, param} = scheme_and_param(part, scheme)

    case param do
      {key, value} when scheme == :digest -> {scheme, Map.put_new(params, key, value)}
      _no_digest_param -> {scheme, params}
    end
  end

  # A part either opens a new challenge (`Digest realm="x"`, or a bare
  # `Negotiate`) or continues the current one (`nonce="y"`). The distinguishing
  # mark is a scheme token followed by whitespace, which a parameter never has
  # before its `=`.
  defp scheme_and_param(part, scheme) do
    case Regex.run(~r/^([A-Za-z][A-Za-z0-9_-]*)(?:\s+(.+))?$/, part) do
      [_match, name] -> {scheme_atom(name), nil}
      [_match, name, rest] -> {scheme_atom(name), parse_param(rest)}
      nil -> {scheme, parse_param(part)}
    end
  end

  defp scheme_atom(name) do
    if String.downcase(name) == "digest", do: :digest, else: :other
  end

  defp parse_param(text) do
    case Regex.run(~r/^([A-Za-z0-9_-]+)\s*=\s*(.*)$/, text) do
      [_match, key, value] -> {String.downcase(key), unquote_value(String.trim(value))}
      nil -> nil
    end
  end

  defp unquote_value(<<"\"", rest::binary>>) do
    String.replace_suffix(rest, "\"", "")
  end

  defp unquote_value(value), do: value

  # Challenge interpretation

  defp hash_algorithm(challenge) do
    algorithm = challenge |> Map.get("algorithm", @default_algorithm) |> String.downcase()

    case Map.fetch(@hashes, algorithm) do
      {:ok, hash} -> {:ok, hash}
      :error -> {:unsupported, "algorithm=#{algorithm}"}
    end
  end

  # `qop` is a comma-separated list of the options the server accepts. Absent
  # entirely means the RFC 2069 form, whose response has no nonce count and no
  # client nonce.
  defp quality_of_protection(challenge) do
    case Map.fetch(challenge, "qop") do
      :error ->
        {:ok, :none}

      {:ok, offered} ->
        options =
          offered |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

        if "auth" in options,
          do: {:ok, :auth},
          else: {:unsupported, "qop=#{offered}"}
    end
  end

  # Header construction

  defp header_value(challenge, hash, qop, method, url, username, password, cnonce) do
    realm = Map.get(challenge, "realm", "")
    nonce = Map.fetch!(challenge, "nonce")
    uri = digest_uri(url)

    ha1 = ha1(challenge, hash, username, realm, password, nonce, cnonce)
    ha2 = hex(hash, "#{method}:#{uri}")

    fields =
      [
        {"username", :quoted, username},
        {"realm", :quoted, realm},
        {"nonce", :quoted, nonce},
        {"uri", :quoted, uri}
      ] ++
        response_fields(qop, hash, ha1, ha2, nonce, cnonce) ++
        echoed_fields(challenge)

    "Digest " <> Enum.map_join(fields, ", ", &render_field/1)
  end

  # RFC 7616, Section 3.4.1: with `qop=auth` the response binds the nonce
  # count and client nonce as well, which is what stops a captured response
  # being replayed.
  defp response_fields(:auth, hash, ha1, ha2, nonce, cnonce) do
    nonce_count = "00000001"
    response = hex(hash, "#{ha1}:#{nonce}:#{nonce_count}:#{cnonce}:auth:#{ha2}")

    [
      {"response", :quoted, response},
      {"qop", :token, "auth"},
      {"nc", :token, nonce_count},
      {"cnonce", :quoted, cnonce}
    ]
  end

  defp response_fields(:none, hash, ha1, ha2, nonce, _cnonce) do
    [{"response", :quoted, hex(hash, "#{ha1}:#{nonce}:#{ha2}")}]
  end

  # `algorithm` goes back exactly as the server wrote it (servers compare it
  # verbatim), and `opaque` must be echoed untouched when offered.
  defp echoed_fields(challenge) do
    Enum.flat_map(
      [{"algorithm", :token}, {"opaque", :quoted}],
      fn {key, form} ->
        case Map.fetch(challenge, key) do
          {:ok, value} -> [{key, form, value}]
          :error -> []
        end
      end
    )
  end

  defp render_field({name, :quoted, value}), do: ~s(#{name}="#{value}")
  defp render_field({name, :token, value}), do: "#{name}=#{value}"

  # RFC 7616, Section 3.4.2. The `-sess` variants fold the nonces into HA1 so
  # the password hash is not reusable across sessions.
  defp ha1(challenge, hash, username, realm, password, nonce, cnonce) do
    secret = hex(hash, "#{username}:#{realm}:#{password}")

    if session_algorithm?(challenge) do
      hex(hash, "#{secret}:#{nonce}:#{cnonce}")
    else
      secret
    end
  end

  defp session_algorithm?(challenge) do
    challenge
    |> Map.get("algorithm", @default_algorithm)
    |> String.downcase()
    |> String.ends_with?("-sess")
  end

  # The digest is computed over the request target, not the whole URL: path
  # plus query, exactly as it appears on the request line.
  defp digest_uri(url) do
    uri = URI.parse(url)
    path = uri.path || "/"

    if uri.query, do: "#{path}?#{uri.query}", else: path
  end

  defp client_nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp hex(hash, data), do: hash |> :crypto.hash(data) |> Base.encode16(case: :lower)
end
