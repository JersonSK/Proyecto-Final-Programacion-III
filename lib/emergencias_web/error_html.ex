defmodule EmergenciasWeb.ErrorHTML do
  @moduledoc "Páginas de error (404, 500...) en texto simple."

  def render(plantilla, _assigns) do
    case plantilla do
      "404.html" -> "Página no encontrada"
      "500.html" -> "Error interno del servidor"
      _ -> Phoenix.Controller.status_message_from_template(plantilla)
    end
  end
end
