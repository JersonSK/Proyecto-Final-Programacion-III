// Conecta la página con su proceso LiveView en el servidor (websocket).
// Phoenix y LiveView se cargan antes desde /vendor (vienen en las dependencias).
(function () {
  var token = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: token }
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
