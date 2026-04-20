defmodule TymeslotWeb.Plugs.UploadStaticSecurity do
  @moduledoc """
  Security wrapper that guards the `/uploads` static-file mount.

  Two concerns:

  * **Extension allowlist.** The upload flows only ever produce images
    (`.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`) and videos (`.mp4`,
    `.webm`, `.mov`). Anything else reaching the upload directory is
    either an attacker artefact that bypassed an upload validator or a
    historical file that should no longer be served. Requests for those
    extensions return `404` before `Plug.Static` touches the filesystem.

  * **MIME sniffing.** `X-Content-Type-Options: nosniff` is added to every
    allowed `/uploads` response so browsers cannot override the
    `Content-Type` that `Plug.Static` sets.

  Must be plugged **before** the `/uploads` `Plug.Static` in the endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  alias TymeslotWeb.Helpers.UploadConstraints

  @uploads_prefix "uploads"

  @allowed_extensions MapSet.new(
                        UploadConstraints.allowed_extensions(:avatar) ++
                          UploadConstraints.allowed_extensions(:image) ++
                          UploadConstraints.allowed_extensions(:video)
                      )

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{halted: true} = conn, _opts), do: conn

  def call(%{path_info: [@uploads_prefix | rest]} = conn, _opts) when rest != [] do
    if allowed_extension?(rest) do
      put_resp_header(conn, "x-content-type-options", "nosniff")
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp allowed_extension?(segments) do
    ext =
      segments
      |> List.last()
      |> Path.extname()
      |> String.downcase()

    MapSet.member?(@allowed_extensions, ext)
  end
end
