from django.shortcuts import render

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
    latitude = request.data.get('latitude')
    longitude = request.data.get('longitude')

    if latitude is None or longitude is None:
        return Response({
            'error': 'latitude and longitude are required'
        },status=400)

    try:
        latitude = float(latitude)
        longitude = float(longitude)
    except (TypeError,ValueError):
        return Response(
            {'error':'Latitude and Longitude must be number'},
            status=400
        )
    if not -90 <= latitude <=90:
        return Response(
            {'error': 'Latitude must be between -90 and 90.'},
            status=400
        )

    if not -180 <= longitude <=180:
        return Response(
            {'error': 'Longitude must be between -90 and 90.'},
            status=400
        )

    location = BoatLocation.objects.create(
        latitude=latitude,
        longitude=longitude
    )

    return Response({
        'message':'Boat Location saved sucessfully',
        'latitude':location.latitude,
        'longitude':location.longitude,
        'timestamp':location.timestamp,

    },status=201)


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