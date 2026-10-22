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

{{/*
Secret holding credentials and URLs. The chart creates `rba-credentials` from
values (k3d); in the cloud OpenTofu creates it and the chart only references
it (`credentials.existingSecret`, ADR-0031).
*/}}
{{- define "rba.secretName" -}}
{{- .Values.credentials.existingSecret | default "rba-credentials" -}}
{{- end }}

{{/*
C-4: "true" when each service creates its schema at startup (k3d), "false"
when the init Jobs do it before the replicas start (`init.mode: job`).
*/}}
{{- define "rba.initOnStartup" -}}
{{- if eq .Values.init.mode "job" }}false{{ else }}true{{ end -}}
{{- end }}
