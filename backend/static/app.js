function fmtHHMM(d=new Date()){
  return d.toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
}
function fmtSS(d=new Date()){
  return d.toLocaleTimeString([], {second:'2-digit'});
}

function updateClock(){
  const now = new Date();
  const el = document.getElementById('clock');
  el.querySelector('.hhmm').textContent = fmtHHMM(now);
  el.querySelector('.ss').textContent = fmtSS(now);
}

function render(summary){
  updateClock();
  const updatedAt = summary.updated_at ? new Date(summary.updated_at*1000) : new Date();
  document.getElementById('updated').textContent = `Updated: ${fmtHHMM(updatedAt)}`;

  const railRows = document.getElementById('rail-rows');
  railRows.innerHTML = '';
  (summary.rail?.stations || []).forEach(st => {
    const gl = document.createElement('div');
    gl.className = 'group-label';
    gl.textContent = st.name || st.code || 'Station';
    railRows.appendChild(gl);
    (st.arrivals || []).forEach(a => {
      const div = document.createElement('div');
      div.className = 'row';
      div.innerHTML = `
        <span class="badge ${a.line}">${a.line}</span>
        <div class="dest">${a.dest || ''}</div>
        <div class="minutes">${a.minutes}</div>
      `;
      railRows.appendChild(div);
    })
  });

  const busRows = document.getElementById('bus-rows');
  busRows.innerHTML = '';
  (summary.bus?.stops || []).forEach(st => {
    const gl = document.createElement('div');
    gl.className = 'group-label';
    gl.textContent = st.name || st.id || 'Stop';
    busRows.appendChild(gl);
    (st.arrivals || []).forEach(a => {
      const div = document.createElement('div');
      div.className = 'row';
      div.innerHTML = `
        <span class="badge">${a.route}</span>
        <div class="dest">${a.headsign || ''}</div>
        <div class="minutes">${a.minutes}</div>
      `;
      busRows.appendChild(div);
    })
  });

  const w = summary.weather?.now || {};
  const iconEl = document.querySelector('#weather .icon');
  const textEl = document.querySelector('#weather .text');
  iconEl.textContent = w.icon || getWeatherIcon(w.summary || '');
  const parts = [];
  if (w.temp_f !== undefined) parts.push(`${Math.round(w.temp_f)}°F`);
  else if (w.temp_c !== undefined) parts.push(`${Math.round(w.temp_c)}°C`);
  if (w.summary) parts.push(w.summary);
  if (w.wind_mph !== undefined) parts.push(`${Math.round(w.wind_mph)} mph wind`);
  else if (w.wind_kph !== undefined) parts.push(`${Math.round(w.wind_kph)} kph wind`);
  textEl.textContent = parts.join(' • ');

  // Hourly forecast strip
  const hourly = summary.weather?.hourly || [];
  const hEl = document.getElementById('hourly');
  hEl.innerHTML = '';
  hourly.forEach(h => {
    const d = new Date(h.time*1000);
    const hh = d.toLocaleTimeString([], {hour:'numeric'});
    const div = document.createElement('div');
    div.className = 'hour';
    div.innerHTML = `
      <div class="hicon">${h.icon || ''}</div>
      <div class="htemp">${Math.round(h.temp_f)}°</div>
      <div class="hpop">${h.pop != null ? (h.pop + '%') : ''}</div>
      <div class="hwhen">${hh}</div>
    `;
    hEl.appendChild(div);
  });

  // Weather alerts
  const wa = summary.weather?.alerts || [];
  const waEl = document.querySelector('#wx-alerts .text');
  waEl.innerHTML = wa.map(a => `<div>${a.event || 'Alert'}: ${a.headline || ''}</div>`).join('');

  const inc = document.getElementById('incidents');
  inc.innerHTML = '<h3>Service Impacts</h3>' + (summary.incidents||[]).map(i=>`<div>${i.text}</div>`).join('');

  const bike = document.getElementById('bike');
  bike.innerHTML = '<h3>Capital Bikeshare — bikes | docks</h3>' + (summary.bike?.stations||[]).map(s=>{
    const eb = (s.ebikes !== undefined && s.ebikes !== null) ? ` • ⚡ ${s.ebikes} e-bikes` : '';
    return `<div>${s.name}: ${s.bikes} bikes • ${s.docks} docks${eb}</div>`;
  }).join('');

  const errs = document.querySelector('#errors .text');
  if (Array.isArray(summary.errors) && summary.errors.length){
    errs.textContent = summary.errors.join('\n');
  } else {
    errs.textContent = '';
  }
}

async function tick(){
  try{
    const res = await fetch('/v1/summary');
    const json = await res.json();
    render(json);
  }catch(e){
    console.error('update failed', e);
  }
}

setInterval(updateClock, 1000);

tick();
setInterval(tick, 10000);

function getWeatherIcon(summary){
  const s = summary.toLowerCase();
  if (s.includes('thunder') || s.includes('storm')) return '⛈️';
  if (s.includes('rain') || s.includes('shower') ) return '🌧️';
  if (s.includes('snow') || s.includes('sleet')) return '🌨️';
  if (s.includes('fog') || s.includes('mist') ) return '🌫️';
  if (s.includes('wind')) return '🌬️';
  if (s.includes('overcast')) return '☁️';
  if (s.includes('cloud')) return '☁️';
  if (s.includes('sun') || s.includes('clear')) return '☀️';
  return '🌡️';
}
