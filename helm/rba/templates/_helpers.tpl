{{/*
Common labels for the local RBA stack.
*/}}
{{- define "rba.labels" -}}
app.kubernetes.io/name: rba
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: rba
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "rba.selector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: rba
{{- end }}

{{- define "rba.wait" -}}
- name: wait-{{ .name }}
  image: {{ .image }}
  command:
    - sh
    - -c
    - until nc -z {{ .host }} {{ .port }}; do echo waiting for {{ .host }}:{{ .port }}; sleep 2; done
{{- end }}
