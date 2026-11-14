defmodule EmergenciasWeb.Router do
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :navegador do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EmergenciasWeb.Layouts, :raiz}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", EmergenciasWeb do
    pipe_through :navegador

    live "/", AccesoLive
    post "/entrar", SesionController, :crear
    get "/salir", SesionController, :eliminar
    live "/panel", PanelLive
    live "/panel/:seccion", PanelLive
  end
end
