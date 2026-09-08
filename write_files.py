  # Run this script to write login.html and register.html
# Command: python write_files.py

login_html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Hepozy - Log in</title>
<link href="https://fonts.googleapis.com/css2?family=Sora:wght@300;400;500;600&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#1a1a1a;--surface:#242424;--input-bg:#2e2e2e;--input-f:#363636;--orange:#e8600a;--orange-h:#d05508;--text:#efefef;--muted:#777;--muted2:#444;--error:#e05555;--radius:9px}
body{min-height:100vh;background:var(--surface);display:flex;align-items:center;justify-content:center;font-family:'Sora',sans-serif;color:var(--text);padding:32px 20px}
.card{width:100%;max-width:400px;background:var(--bg);border-radius:16px;padding:40px 36px 32px}
.logo{width:40px;height:40px;background:var(--orange);border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:15px;font-weight:600;color:#fff;margin-bottom:22px}
h1{font-size:21px;font-weight:600;margin-bottom:5px}
.sub{font-size:13px;color:var(--muted);margin-bottom:28px}
.err{display:none;background:rgba(224,85,85,0.1);color:var(--error);font-size:12.5px;padding:9px 12px;border-radius:var(--radius);margin-bottom:16px}
.err.show{display:block}
.field{margin-bottom:16px}
label{display:block;font-size:11.5px;font-weight:500;color:var(--muted);margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px}
input{width:100%;background:var(--input-bg);border:none;outline:none;border-radius:var(--radius);padding:11px 13px;font-size:13.5px;font-family:'Sora',sans-serif;color:var(--text)}
input:focus{background:var(--input-f)}
input::placeholder{color:var(--muted2)}
.btn{width:100%;padding:12px;background:var(--orange);color:#fff;border:none;border-radius:var(--radius);font-size:13.5px;font-weight:600;font-family:'Sora',sans-serif;cursor:pointer;margin-top:6px;transition:background 0.14s;min-height:44px}
.btn:hover{background:var(--orange-h)}
.btn:disabled{opacity:0.6;cursor:not-allowed}
.foot{margin-top:20px;font-size:12.5px;color:var(--muted);text-align:center}
.foot a{color:var(--orange);text-decoration:none;font-weight:500}
</style>
</head>
<body>
<div class="card">
<div class="logo">H</div>
<h1>Welcome back</h1>
<p class="sub">Log in to your account to continue.</p>
<div class="err" id="err"></div>
<form id="form">
<div class="field"><label>Username</label><input type="text" id="username" placeholder="Enter your username" required></div>
<div class="field"><label>Password</label><input type="password" id="password" placeholder="Enter your password" required></div>
<button type="submit" class="btn" id="btn">Log in</button>
</form>
<div class="foot">No account yet? <a href="register.html">Create account</a></div>
</div>
<script>
const API = 'http://localhost:8000';
if (localStorage.getItem('hepozy_token')) window.location.href = 'home.html';
document.getElementById('form').addEventListener('submit', async e => {
  e.preventDefault();
  const err = document.getElementById('err');
  const btn = document.getElementById('btn');
  err.classList.remove('show');
  btn.disabled = true;
  btn.textContent = 'Please wait...';
  const username = document.getElementById('username').value.trim();
  const password = document.getElementById('password').value;
  try {
    const res  = await fetch(API + '/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    });
    const data = await res.json();
    if (!res.ok) {
      err.textContent = data.detail || 'Login failed.';
      err.classList.add('show');
      btn.disabled = false;
      btn.textContent = 'Log in';
      return;
    }
    localStorage.setItem('hepozy_token', data.token);
    localStorage.setItem('hepozy_username', data.username);
    window.location.href = 'home.html';
  } catch {
    err.textContent = 'Unable to connect to server. Please try again.';
    err.classList.add('show');
    btn.disabled = false;
    btn.textContent = 'Log in';
  }
});
</script>
</body>
</html>"""

register_html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Hepozy - Create account</title>
<link href="https://fonts.googleapis.com/css2?family=Sora:wght@300;400;500;600&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#1a1a1a;--surface:#242424;--input-bg:#2e2e2e;--input-f:#363636;--orange:#e8600a;--orange-h:#d05508;--text:#efefef;--muted:#777;--muted2:#444;--error:#e05555;--radius:9px}
body{min-height:100vh;background:var(--surface);display:flex;align-items:center;justify-content:center;font-family:'Sora',sans-serif;color:var(--text);padding:32px 20px}
.card{width:100%;max-width:400px;background:var(--bg);border-radius:16px;padding:40px 36px 32px}
.logo{width:40px;height:40px;background:var(--orange);border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:15px;font-weight:600;color:#fff;margin-bottom:22px}
h1{font-size:21px;font-weight:600;margin-bottom:5px}
.sub{font-size:13px;color:var(--muted);margin-bottom:28px}
.err{display:none;background:rgba(224,85,85,0.1);color:var(--error);font-size:12.5px;padding:9px 12px;border-radius:var(--radius);margin-bottom:16px}
.err.show{display:block}
.field{margin-bottom:16px}
label{display:block;font-size:11.5px;font-weight:500;color:var(--muted);margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px}
input{width:100%;background:var(--input-bg);border:none;outline:none;border-radius:var(--radius);padding:11px 13px;font-size:13.5px;font-family:'Sora',sans-serif;color:var(--text)}
input:focus{background:var(--input-f)}
input::placeholder{color:var(--muted2)}
.btn{width:100%;padding:12px;background:var(--orange);color:#fff;border:none;border-radius:var(--radius);font-size:13.5px;font-weight:600;font-family:'Sora',sans-serif;cursor:pointer;margin-top:6px;transition:background 0.14s;min-height:44px}
.btn:hover{background:var(--orange-h)}
.btn:disabled{opacity:0.6;cursor:not-allowed}
.foot{margin-top:20px;font-size:12.5px;color:var(--muted);text-align:center}
.foot a{color:var(--orange);text-decoration:none;font-weight:500}
</style>
</head>
<body>
<div class="card">
<div class="logo">H</div>
<h1>Create account</h1>
<p class="sub">Sign up to get started.</p>
<div class="err" id="err"></div>
<form id="form">
<div class="field"><label>Email</label><input type="email" id="email" placeholder="Enter your email" required></div>
<div class="field"><label>Username</label><input type="text" id="username" placeholder="Choose a username" required></div>
<div class="field"><label>Password</label><input type="password" id="password" placeholder="Create a password" required></div>
<div class="field"><label>Confirm Password</label><input type="password" id="confirm" placeholder="Repeat your password" required></div>
<button type="submit" class="btn" id="btn">Create account</button>
</form>
<div class="foot">Already have an account? <a href="login.html">Log in</a></div>
</div>
<script>
const API = 'http://localhost:8000';
if (localStorage.getItem('hepozy_token')) window.location.href = 'home.html';
document.getElementById('form').addEventListener('submit', async e => {
  e.preventDefault();
  const err = document.getElementById('err');
  const btn = document.getElementById('btn');
  err.classList.remove('show');
  btn.disabled = true;
  btn.textContent = 'Please wait...';
  const email    = document.getElementById('email').value.trim();
  const username = document.getElementById('username').value.trim();
  const password = document.getElementById('password').value;
  const confirm  = document.getElementById('confirm').value;
  if (password.length < 8) {
    err.textContent = 'Password must be at least 8 characters.';
    err.classList.add('show');
    btn.disabled = false;
    btn.textContent = 'Create account';
    return;
  }
  if (password !== confirm) {
    err.textContent = 'Passwords do not match.';
    err.classList.add('show');
    btn.disabled = false;
    btn.textContent = 'Create account';
    return;
  }
  try {
    const res  = await fetch(API + '/auth/signup', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, username, password })
    });
    const data = await res.json();
    if (!res.ok) {
      err.textContent = data.detail || 'Sign up failed.';
      err.classList.add('show');
      btn.disabled = false;
      btn.textContent = 'Create account';
      return;
    }
    localStorage.setItem('hepozy_token', data.token);
    localStorage.setItem('hepozy_username', data.username);
    window.location.href = 'home.html';
  } catch {
    err.textContent = 'Unable to connect to server. Please try again.';
    err.classList.add('show');
    btn.disabled = false;
    btn.textContent = 'Create account';
  }
});
</script>
</body>
</html>"""

with open('login.html', 'w', encoding='utf-8') as f:
    f.write(login_html)
print('login.html written')

with open('register.html', 'w', encoding='utf-8') as f:
    f.write(register_html)
print('register.html written')

import os
if os.path.exists('log,reg.js'):
    os.remove('log,reg.js')
    print('log,reg.js deleted')

print('All done. Run: python hpz.py')
