from django.shortcuts import render
import secrets

from django.conf import settings




# Create your views here.
from django.http import HttpResponse
from rest_framework.decorators import api_view
from rest_framework.response import Response
from .models import BoatLocation

@api_view(['GET'])
def home(request):
    return Response({
        'message':'Arnala boat tracker API is wroking.'
    })

@api_view(['POST'])
def recieve_location(request):

    # 1. Authenticate the boat's Android device
    expected_token = settings.BOAT_DEVICE_TOKEN
    supplied_token = request.headers.get('X-Boat-Device-Token', '')

    if not expected_token:
        return Response(
            {'error': 'Boat device authentication is not configured.'},
            status=503
        )

    if not secrets.compare_digest(supplied_token, expected_token):
        return Response(
            {'error': 'Invalid device token.'},
            status=403
        )

    # 2. Read coordinates
    latitude = request.data.get('latitude')
    longitude = request.data.get('longitude')

    if latitude is None or longitude is None:
        return Response(
            {'error': 'Latitude and longitude are required.'},
            status=400
        )

    # 3. Validate numeric values
    try:
        latitude = float(latitude)
        longitude = float(longitude)
    except (TypeError, ValueError):
        return Response(
            {'error': 'Latitude and longitude must be numbers.'},
            status=400
        )

    # Reject NaN and infinity
    if not (-90 <= latitude <= 90):
        return Response(
            {'error': 'Latitude must be between -90 and 90.'},
            status=400
        )

    if not (-180 <= longitude <= 180):
        return Response(
            {'error': 'Longitude must be between -180 and 180.'},
            status=400
        )

    # 4. Save the boat's location
    location = BoatLocation.objects.create(
        latitude=latitude,
        longitude=longitude
    )

    # 5. Return successful response
    return Response(
        {
            'message': 'Boat location saved successfully.',
            'latitude': location.latitude,
            'longitude': location.longitude,
            'timestamp': location.timestamp
        },
        status=201
    )


@api_view(['GET'])
def latest_location(request):
    location = BoatLocation.objects.order_by('-timestamp').first()
    if location is None:
        return Response(
            {'message':'No boat location recorded yet.'},status=404
        )
    
    return Response({
        'latitude':location.latitude,
        'longitude':location.longitude,
        'timestamp':location.timestamp,
    })