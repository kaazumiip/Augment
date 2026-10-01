FROM python:3.11-bookworm AS sfizz-build
RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake build-essential libsndfile1-dev && rm -rf /var/lib/apt/lists/*
RUN git clone --branch 1.2.3 --depth 1 --recurse-submodules \
    https://github.com/sfztools/sfizz.git /src/sfizz
RUN cmake -S /src/sfizz -B /src/sfizz/build \
    -DCMAKE_BUILD_TYPE=Release -DSFIZZ_RENDER=ON -DSFIZZ_SHARED=OFF \
    -DSFIZZ_JACK=OFF -DSFIZZ_TESTS=OFF \
    && cmake --build /src/sfizz/build --target sfizz_render --parallel 2

FROM python:3.11-bookworm
ENV PYTHONUNBUFFERED=1 QT_QPA_PLATFORM=offscreen \
    MUSESCORE_PATH=/usr/bin/musescore3 \
    AUGMENT_SFIZZ_RENDER_PATH=/usr/local/bin/sfizz_render \
    OMP_NUM_THREADS=2 OPENBLAS_NUM_THREADS=2
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg libfluidsynth3 libsndfile1 musescore3 lilypond fonts-dejavu \
    && rm -rf /var/lib/apt/lists/*
COPY --from=sfizz-build /src/sfizz/build/clients/sfizz_render /usr/local/bin/sfizz_render
WORKDIR /app
COPY requirements.txt requirements-hosting.txt ./
# Install CPU wheels first: no CUDA runtime is needed on this demo service.
RUN pip install --no-cache-dir torch==2.5.1 torchaudio==2.5.1 \
    --index-url https://download.pytorch.org/whl/cpu \
    && pip install --no-cache-dir -r requirements-hosting.txt
COPY *.py ./
RUN mkdir -p uploads output soundfonts resources
# Provide licensed sound libraries separately; they are not in the public repo.
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT:-5000} --workers 1 --threads 4 --timeout 1800 app:app"]
