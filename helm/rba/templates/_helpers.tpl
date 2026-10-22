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

{{/*
Image reference: "<registry>/<name>:<tag>", or "<name>:<tag>" when no
registry is set (k3d imports images by bare name).
*/}}
{{- define "rba.image" -}}
{{- $r := .root.Values.images.registry -}}
{{- if $r }}{{ $r }}/{{ end }}{{ .name }}:{{ .root.Values.images.tag }}
{{- end }}

{{/*
ALB annotations for an Ingress (cloud). All of the chart's and the demo's
Ingresses join one ALB (`group.name`), and each rule also requires the secret
header CloudFront adds, so the ALB answers nothing that bypassed CloudFront.
*/}}
{{- define "rba.ingressAnnotations" -}}
{{- with .root.Values.ingress.annotations }}
{{ toYaml . }}
{{- end }}
{{- with .root.Values.ingress.originVerify }}
alb.ingress.kubernetes.io/conditions.{{ $.service }}: '[{"field":"http-header","httpHeaderConfig":{"httpHeaderName":"X-Origin-Verify","values":["{{ . }}"]}}]'
alb.ingress.kubernetes.io/healthcheck-path: {{ $.health | quote }}
{{- end }}
{{- end }}

{{/*
The IdP's environment. Shared by the Deployment and its init Job, so the Job
seeds with the same redirect URIs and password suffix, and passes the same
DEPLOYMENT=cloud validation.
*/}}
{{- define "rba.idpEnv" -}}
- name: INIT_ON_STARTUP
  value: "{{ include "rba.initOnStartup" . }}"
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "rba.secretName" . }}
      key: IDP_DATABASE_URL
- name: PDP_BASE_URL
  value: "http://decision-service:{{ .Values.apps.decisionService.port }}"
- name: AUDIT_BASE_URL
  value: "http://decision-service:{{ .Values.apps.decisionService.port }}"
- name: SEED_BANK_REDIRECT_URI
  value: {{ .Values.apps.idp.seedRedirectUri | quote }}
- name: WEBAUTHN_RP_ID
  value: {{ .Values.apps.idp.webauthnRpId | quote }}
- name: WEBAUTHN_ORIGIN
  value: {{ .Values.apps.idp.webauthnOrigin | quote }}
{{- range $name, $value := .Values.apps.idp.env }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- range $name, $key := .Values.apps.idp.secretEnv }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "rba.secretName" $ }}
      key: {{ $key }}
{{- end }}
{{- end }}
