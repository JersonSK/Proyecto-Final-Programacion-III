defmodule EmergenciasWeb.Endpoint do
  @moduledoc """
  Punto de entrada HTTP de la interfaz web. Atiende las páginas, los archivos
  estáticos y el websocket de LiveView: cada navegador conectado queda atendido
  por su propio proceso LiveView dentro del nodo servidor.
  """

  use Phoenix.Endpoint, otp_app: :emergencias

  # La sesión se guarda en una cookie firmada (solo contiene el nombre de usuario).
  @sesion [
    store: :cookie,
    key: "_emergencias",
    signing_salt: "x4Vb9QeR",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @sesion]],
    longpoll: [connect_info: [session: @sesion]]

  # Estilos y script propios (priv/static).
  plug Plug.Static, at: "/", from: :emergencias, gzip: false, only: ~w(css js favicon.svg)

  # Los clientes JavaScript de Phoenix y LiveView vienen ya compilados en sus
  # dependencias, así que no hace falta Node.js ni un empaquetador.
  plug Plug.Static, at: "/vendor", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.RequestId

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @sesion
  plug EmergenciasWeb.Router
end
