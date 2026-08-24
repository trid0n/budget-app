$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://localhost:8973/')
$listener.Start()
$root = $PSScriptRoot
while($listener.IsListening){
  $ctx = $listener.GetContext()
  $path = $ctx.Request.Url.LocalPath
  if($path -eq '/' -or $path -eq ''){ $path = '/index-test.html' }
  $file = Join-Path $root ($path.TrimStart('/'))
  if(Test-Path $file -PathType Leaf){
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $ctx.Response.ContentType = if($file -like '*.html'){'text/html; charset=utf-8'} else {'application/octet-stream'}
    $ctx.Response.AddHeader('Cache-Control','no-store')
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length)
  } else { $ctx.Response.StatusCode = 404 }
  $ctx.Response.Close()
}
